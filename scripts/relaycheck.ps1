# Two-process relay acceptance test, over real UDP.
#
# Launches the reference relay as one OS process and the relay check as another,
# and asserts that a real dedicated host and a real client complete a real
# handshake through a machine neither of them addresses directly.
#
#   powershell -ExecutionPolicy Bypass -File scripts\relaycheck.ps1
#   ... -Port 6790 -Love "F:\LOVE\lovec.exe" -KeepLogs
#
# Why two processes and not one: with the relay in the same process, the dial in
# meatray/net/transport/relay.lua is satisfied by an in-process pump and never
# does the blocking wait it was written for. Across two processes it does, over a
# real socket, and a relay that never answered would have to be given up on
# rather than waited for forever.
#
# The headless suite (`luajit tests/run_all.lua`) covers the session logic, the
# frame format, the caps, the budgets and the failure paths with no sockets at
# all. This covers the half that needs one.
#
# Exit 0 when the check passed. Any stray lovec.exe is killed on the way in and
# on the way out, because a relay left listening makes the next run pass for the
# wrong reason.

param(
    [int]$Port = 6790,
    [string]$Love = 'F:\LOVE\lovec.exe',
    [int]$TimeoutSeconds = 120,
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $env:TEMP ('meatray-relaycheck-' + $PID)
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Say($text) { Write-Host $text }
function Rule { Write-Host ('=' * 70) }

function Kill-Strays {
    Get-Process -Name 'lovec', 'love' -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
        }
}

function Show-Log($title, $path) {
    Rule
    Say $title
    Rule
    if (Test-Path $path) {
        Get-Content $path | ForEach-Object { Write-Host $_ }
    } else {
        Say '(no output)'
    }
}

$relayLog = Join-Path $logDir 'relay.log'
$checkLog = Join-Path $logDir 'check.log'

$failures = @()
$relay = $null

try {
    Say 'MeatRayCast relay acceptance test'
    Say "  love    : $Love"
    Say "  project : $root"
    Say "  port    : $Port"
    Say "  logs    : $logDir"
    Rule

    if (-not (Test-Path $Love)) { throw "LOVE not found at $Love" }

    Kill-Strays

    # ----------------------------------------------------------------- relay
    Say '[run] starting the relay'
    $relay = Start-Process -FilePath $Love `
        -ArgumentList @('relayserver', '--port', "$Port") `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardOutput $relayLog `
        -RedirectStandardError (Join-Path $logDir 'relay.err')
    $null = $relay.Handle

    # A generous, stated budget for the relay to bind its socket. Three seconds
    # is far longer than a bind takes and far shorter than anyone would notice;
    # an under-tight one here would report a working relay as a dead one, which
    # is the misdiagnosis this project has already paid for.
    $bound = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 100
        if ($relay.HasExited) { break }
        if ((Test-Path $relayLog) -and
            ((Get-Content $relayLog -Raw) -match 'listening on UDP')) {
            $bound = $true
            break
        }
    }

    if ($relay.HasExited) {
        Show-Log 'RELAY' $relayLog
        throw "the relay exited immediately (exit $($relay.ExitCode))"
    }
    if (-not $bound) {
        Say '[warn] the relay did not say it was listening within 3s; trying anyway'
    } else {
        Say "[run] relay listening on UDP $Port"
    }

    # ----------------------------------------------------------------- check
    Say '[run] host + client, through the relay'
    $check = Start-Process -FilePath $Love `
        -ArgumentList @('relaycheck', '--relay', "127.0.0.1:$Port", '--timeout', '45') `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardOutput $checkLog `
        -RedirectStandardError (Join-Path $logDir 'check.err')
    $null = $check.Handle

    $check.WaitForExit($TimeoutSeconds * 1000) | Out-Null

    if (-not $check.HasExited) {
        Stop-Process -Id $check.Id -Force
        $failures += 'the check hung'
    } elseif ($check.ExitCode -ne 0) {
        $failures += "the check failed (exit $($check.ExitCode))"
    }

    Show-Log 'CHECK' $checkLog
    Show-Log 'RELAY' $relayLog

} catch {
    $failures += $_.Exception.Message
} finally {
    if ($relay -and -not $relay.HasExited) {
        try { Stop-Process -Id $relay.Id -Force -ErrorAction Stop } catch {}
    }
    Kill-Strays
}

Rule
if ($failures.Count -eq 0) {
    Say 'PASS - a real host and a real client played through a real relay.'
    if (-not $KeepLogs) { Remove-Item -Recurse -Force $logDir -ErrorAction SilentlyContinue }
    exit 0
} else {
    Say 'FAIL'
    foreach ($line in $failures) { Say "  - $line" }
    Say "logs kept in $logDir"
    exit 1
}
