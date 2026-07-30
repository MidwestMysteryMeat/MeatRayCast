# Two-process (three, in fact) network acceptance test.
#
# Launches a headless dedicated server and two headless clients as separate OS
# processes and asserts across real UDP. This is the test the in-process
# replication suite cannot be: three copies of the simulation, one authoritative,
# and a real socket between them.
#
#   powershell -ExecutionPolicy Bypass -File scripts\nettest.ps1
#   ... -Port 6789 -Love "F:\LOVE\lovec.exe" -KeepLogs
#
# Exit 0 when every process passed. Any stray lovec.exe is killed on the way in
# and on the way out, because a server left listening makes the next run pass for
# the wrong reason.

param(
    [int]$Port = 6789,
    [string]$Love = 'F:\LOVE\lovec.exe',
    [string]$Map = 'arena',
    [int]$TimeoutSeconds = 120,
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $env:TEMP ('meatray-nettest-' + $PID)
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

$serverLog = Join-Path $logDir 'server.log'
$logA      = Join-Path $logDir 'client-a.log'
$logB      = Join-Path $logDir 'client-b.log'
$browseLog = Join-Path $logDir 'browse.log'

$failures = @()

try {
    Say "MeatRayCast two-process network test"
    Say "  love    : $Love"
    Say "  project : $root"
    Say "  port    : $Port  map: $Map"
    Say "  logs    : $logDir"
    Rule

    if (-not (Test-Path $Love)) { throw "LOVE not found at $Love" }

    Kill-Strays

    # ---------------------------------------------------------------- server
    Say '[run] starting headless dedicated server'
    $server = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--server', '--port', "$Port", '--map', $Map,
                        '--name', 'nettest-server', '--log', $serverLog) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'server.err')
    $null = $server.Handle

    # Wait for the port to be open rather than for a fixed sleep: a sleep that is
    # long enough on this machine is a race on a slower one.
    $ready = $false
    for ($i = 0; $i -lt 200; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path $serverLog) {
            $text = Get-Content $serverLog -Raw -ErrorAction SilentlyContinue
            if ($text -and $text -match "listening on UDP $Port") { $ready = $true; break }
        }
        if ($server.HasExited) { break }
    }

    if (-not $ready) {
        $failures += 'the dedicated server never reported that it was listening'
        Show-Log 'SERVER OUTPUT' $serverLog
        throw 'server did not come up'
    }
    Say "[run] server is listening on UDP $Port (pid $($server.Id))"

    # ------------------------------------------------------------- discovery
    # Step 4 verified for real: a separate process finds the server by UDP
    # broadcast with nothing configured.
    Say '[run] LAN discovery: browsing for the server from another process'
    $browse = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--browse', '--log', $browseLog) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'browse.err')
    $null = $browse.Handle
    $browse.WaitForExit(30000) | Out-Null
    if (-not $browse.HasExited) {
        Stop-Process -Id $browse.Id -Force
        $failures += 'the LAN browser hung'
    } else {
        Say "[run] LAN browser exited $($browse.ExitCode)"
        if ($browse.ExitCode -ne 0) {
            $failures += "the LAN browser did not find the server (exit $($browse.ExitCode))"
        }
    }

    # --------------------------------------------------------------- clients
    # b first: it is the observer and must be present before a acts.
    Say '[run] starting client b (observer)'
    $clientB = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--nettest', '--connect', "127.0.0.1:$Port",
                        '--role', 'b', '--log', $logB) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'client-b.err')
    $null = $clientB.Handle

    Start-Sleep -Milliseconds 800

    Say '[run] starting client a (actor)'
    $clientA = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--nettest', '--connect', "127.0.0.1:$Port",
                        '--role', 'a', '--log', $logA) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'client-a.err')
    $null = $clientA.Handle

    $clientA.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    $clientB.WaitForExit($TimeoutSeconds * 1000) | Out-Null

    foreach ($pair in @(@('a', $clientA), @('b', $clientB))) {
        $role = $pair[0]; $proc = $pair[1]
        if (-not $proc.HasExited) {
            $failures += "client $role timed out after $TimeoutSeconds s"
            try { Stop-Process -Id $proc.Id -Force } catch {}
        } else {
            Say "[run] client $role exited $($proc.ExitCode)"
            if ($proc.ExitCode -ne 0) { $failures += "client $role exited $($proc.ExitCode)" }
        }
    }

    Show-Log 'SERVER OUTPUT'    $serverLog
    Show-Log 'LAN BROWSER'      $browseLog
    Show-Log 'CLIENT A (actor)' $logA
    Show-Log 'CLIENT B (observer)' $logB

    foreach ($path in @($logA, $logB)) {
        if (Test-Path $path) {
            $text = Get-Content $path -Raw
            if ($text -notmatch 'NETTEST PASSED') {
                $failures += ((Split-Path -Leaf $path) + ' did not report NETTEST PASSED')
            }
        } else {
            $failures += ((Split-Path -Leaf $path) + ' produced no output')
        }
    }
}
finally {
    Kill-Strays
    Rule
    if ($failures.Count -eq 0) {
        Say 'NETTEST SUITE PASSED'
        if (-not $KeepLogs) { Remove-Item -Recurse -Force $logDir -ErrorAction SilentlyContinue }
        exit 0
    } else {
        Say 'NETTEST SUITE FAILED'
        $failures | ForEach-Object { Say ('  - ' + $_) }
        Say "logs kept at: $logDir"
        exit 1
    }
}
