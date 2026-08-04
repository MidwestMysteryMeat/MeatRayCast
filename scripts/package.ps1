# Release packaging (G8).
#
#   powershell -ExecutionPolicy Bypass -File scripts\package.ps1
#   ... -Love "F:\LOVE" -Out "F:\dist" -NoSmoke
#
# Builds a fused, self-contained Windows build: main.lua + conf.lua + the
# engine + the maps, zipped into a .love, concatenated onto love.exe, with the
# LÖVE runtime DLLs beside it. Strips the editor, the tests, the docs and the
# dev scripts — a player double-clicks the .exe and reaches the title screen
# (G1); none of the authoring or measurement machinery ships.
#
# The version is `git describe`, stamped into the folder and archive name so a
# build is traceable to a commit. The last step boots the fused exe and checks
# it is still alive after a few seconds — the Wave G exit criterion, verified
# by the build rather than asserted in a doc.

param(
    [string]$Love = 'F:\LOVE',
    [string]$Out = "$PSScriptRoot\..\build",
    # H2: a game project folder (see docs/GETTING_STARTED.md). The project is
    # staged into the fuse at project/, where main.lua auto-mounts it, and the
    # build takes the project's name and version instead of the engine's.
    [string]$Project = '',
    [switch]$NoSmoke
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path "$PSScriptRoot\.."
Set-Location $repo

# --- version ---------------------------------------------------------------
$version = (& git describe --tags --always --dirty 2>$null)
if (-not $version) { $version = 'dev' }
$version = $version.Trim()

# --- project ---------------------------------------------------------------
$gameName = 'MeatRayCast'
if ($Project) {
    $Project = Resolve-Path $Project
    $manifestPath = Join-Path $Project 'project.json'
    if (-not (Test-Path $manifestPath)) { throw "no project.json in $Project" }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.id) { throw "$manifestPath has no id" }
    $gameName = ($manifest.name -replace '[^\w\-\. ]', '').Trim()
    if (-not $gameName) { $gameName = $manifest.id }
    if ($manifest.version) { $version = "$($manifest.version)+engine.$version" }
    Write-Host "Packaging project '$gameName' $version" -ForegroundColor Cyan
} else {
    Write-Host "Packaging MeatRayCast $version" -ForegroundColor Cyan
}

# --- what ships ------------------------------------------------------------
# The game and the engine, and nothing that authors, tests or measures it.
$includeFiles = @(
    'main.lua', 'conf.lua',
    # Runtime diagnostics a player or server operator can legitimately use.
    'browse.lua', 'netcheck.lua', 'punchcheck.lua'
)
$includeDirs = @('meatray', 'app', 'maps', 'meatgraphs')

# Named so the intent is on the page: these are stripped on purpose.
$excluded = @(
    'editor.lua (authoring)', 'bench.lua / selftest.lua / nettest.lua / netfrag.lua / netproxy.lua (dev)',
    'tests/ docs/ scripts/ (not shipped)', 'masterserver/ relayserver/ (separate programs)'
)

# --- stage -----------------------------------------------------------------
$stage = Join-Path $Out "stage"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

foreach ($f in $includeFiles) {
    if (Test-Path $f) { Copy-Item $f -Destination $stage }
    else { Write-Host "  (skip missing $f)" -ForegroundColor DarkYellow }
}
foreach ($d in $includeDirs) {
    Copy-Item $d -Destination $stage -Recurse
}

# H2: the project rides inside the fuse at project/ — main.lua looks there at
# boot and mounts what it finds, so the packaged exe IS the project's game.
if ($Project) {
    Copy-Item $Project -Destination (Join-Path $stage 'project') -Recurse
}

# A build stamp the running game could read, and a human can eyeball.
Set-Content -Path (Join-Path $stage 'VERSION') -Value $version -NoNewline

# Belt and braces: nothing the .gitignore keeps out should ride along in a
# copied tree either (a stray .png from a scratch run, say). The project's
# own assets are exempt — a game's art and sound are exactly what ships.
Get-ChildItem $stage -Recurse -Include *.png,*.psd,*.xcf,*.wav,*.ogg |
    Where-Object { $_.FullName -notmatch '\\docs\\media\\' -and
                   $_.FullName -notmatch '\\stage\\project\\' } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# --- .love (zip with main.lua at the ROOT) ---------------------------------
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$loveFile = Join-Path $Out "$gameName-$version.love"
if (Test-Path $loveFile) { Remove-Item -Force $loveFile }
# Compress the CONTENTS of stage (the \* matters: main.lua must sit at the zip
# root, or LÖVE cannot find it).
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath "$loveFile.zip" -Force
Move-Item "$loveFile.zip" $loveFile -Force
Write-Host "  .love: $loveFile ($([math]::Round((Get-Item $loveFile).Length/1kb)) KB)"

# --- fuse onto love.exe ----------------------------------------------------
$loveExe = Join-Path $Love 'love.exe'
if (-not (Test-Path $loveExe)) { throw "love.exe not found at $loveExe (pass -Love)" }

$dist = Join-Path $Out "$gameName-$version"
if (Test-Path $dist) { Remove-Item -Recurse -Force $dist }
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$fusedExe = Join-Path $dist "$gameName.exe"
# Concatenate as BINARY: love.exe followed by the .love archive is how a fused
# LÖVE game is made. cmd's copy /b is the reliable way to do a binary join.
& cmd /c copy /b "`"$loveExe`"+`"$loveFile`"" "`"$fusedExe`"" | Out-Null

# The runtime DLLs live beside the exe. love.dll is required; the rest are the
# media/codec/GL stack LÖVE loads.
Get-ChildItem $Love -Filter *.dll | Copy-Item -Destination $dist
Copy-Item $loveFile -Destination (Join-Path $dist "game.love") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $dist "game.love") -ErrorAction SilentlyContinue

Write-Host "  fused: $fusedExe" -ForegroundColor Green
$dllCount = (Get-ChildItem $dist -Filter *.dll).Count
Write-Host "  + $dllCount runtime DLLs"

# --- smoke: does a stranger's double-click reach the game? -----------------
if (-not $NoSmoke) {
    Write-Host "Smoke-booting the fused build..." -ForegroundColor Cyan
    $errLog = Join-Path $Out 'smoke.err'
    $p = Start-Process $fusedExe -PassThru -WindowStyle Minimized `
         -RedirectStandardError $errLog
    Start-Sleep -Seconds 5
    $alive = -not $p.HasExited
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $err = if (Test-Path $errLog) { (Get-Content $errLog -Raw) } else { '' }

    if ($alive -and [string]::IsNullOrWhiteSpace($err)) {
        Write-Host "  SMOKE OK: booted, ran 5s, no errors" -ForegroundColor Green
    } else {
        Write-Host "  SMOKE FAILED (alive=$alive)" -ForegroundColor Red
        if ($err) { Write-Host $err }
        exit 1
    }
}

Write-Host ""
Write-Host "Release ready: $dist" -ForegroundColor Green
Write-Host "Stripped: $($excluded -join '; ')" -ForegroundColor DarkGray
exit 0
