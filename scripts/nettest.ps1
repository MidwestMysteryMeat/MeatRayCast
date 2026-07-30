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
    [switch]$Listen,
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

$checkLog  = Join-Path $logDir 'netcheck.log'
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

    # ------------------------------------------------------------- netcheck
    # Run first, and stop here if it fails.
    #
    # A machine where something is filtering UDP produces exactly the symptoms of a
    # broken handshake: clients sit on 'connecting' and the LAN browser finds
    # nothing. Reporting that as a failed handshake sends the next person hunting a
    # bug that is not there, so the environment is established before anything is
    # asserted about the code. `--netcheck` tests LuaSocket, lua-enet, a loopback
    # UDP round trip, the bind, and a real ENet handshake between two peers in one
    # process - all with no MeatRayCast networking involved beyond the transport.
    Say '[run] netcheck: can this machine do UDP at all?'
    $check = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--netcheck', '--port', "$Port", '--log', $checkLog) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'netcheck.err')
    $null = $check.Handle
    $check.WaitForExit(60000) | Out-Null

    if (-not $check.HasExited) {
        Stop-Process -Id $check.Id -Force
        $failures += 'netcheck hung'
    } elseif ($check.ExitCode -ne 0) {
        Show-Log 'NETCHECK' $checkLog
        Rule
        switch ($check.ExitCode) {
            4 {
                Say 'UDP IS BLOCKED ON THIS MACHINE - this is not a bug in MeatRayCast.'
                Say ''
                Say 'A UDP datagram could not cross this machine to itself, so no'
                Say 'handshake can possibly complete and LAN discovery cannot possibly'
                Say 'find anything. Do not go looking in the handshake code.'
                Say ''
                Say 'Fix it from an ADMINISTRATOR PowerShell:'
                Say ''
                Say ('  New-NetFirewallRule -DisplayName "LOVE UDP in" -Direction Inbound ' +
                     '-Program "' + $Love + '" -Protocol UDP -Action Allow')
                Say ('  New-NetFirewallRule -DisplayName "LOVE UDP out" -Direction Outbound ' +
                     '-Program "' + $Love + '" -Protocol UDP -Action Allow')
                Say ''
                Say 'Endpoint protection and VPN clients with filtering drivers cause the'
                Say 'same symptom and are not fixed by a firewall rule; disable them to test.'
                Say ''
                Say 'Then re-check with:  & "' + $Love + '" . --netcheck'
                $failures += 'UDP is blocked on this machine (environmental, not a code fault)'
            }
            5 {
                Say ("UDP $Port COULD NOT BE BOUND - something else is using it.")
                Say ("Re-run with a different port:  -Port " + ($Port + 1))
                $failures += "UDP $Port could not be bound"
            }
            6 {
                Say 'lua-enet or LuaSocket is missing from this LOVE build.'
                Say 'Both ship with a stock LOVE install; this one is stripped or is not LOVE.'
                $failures += 'lua-enet or LuaSocket is missing'
            }
            default {
                Say 'netcheck failed: UDP works and the port binds, but two ENet peers'
                Say 'in one process could not complete a handshake. That is below the'
                Say 'game layer - suspect the transport or the ENet build, not replication.'
                $failures += "netcheck failed (exit $($check.ExitCode))"
            }
        }
        throw 'environment check failed'
    } else {
        Say '[run] netcheck passed'
    }

    # ---------------------------------------------------------------- server
    $hostFlag = if ($Listen) { '--host' } else { '--server' }
    $hostKind = if ($Listen) { 'listen host (windowed)' } else { 'headless dedicated server' }
    Say "[run] starting $hostKind"
    $server = Start-Process -FilePath $Love `
        -ArgumentList @('.', $hostFlag, '--port', "$Port", '--map', $Map,
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
    # b first: it is the observer and must be present before a acts. A listen host
    # is already a second player, so b is only needed for the dedicated case.
    $clientB = $null
    if (-not $Listen) {
        Say '[run] starting client b (observer)'
        $clientB = Start-Process -FilePath $Love `
            -ArgumentList @('.', '--nettest', '--connect', "127.0.0.1:$Port",
                            '--role', 'b', '--log', $logB) `
            -WorkingDirectory $root -PassThru -NoNewWindow `
            -RedirectStandardError (Join-Path $logDir 'client-b.err')
        $null = $clientB.Handle

        Start-Sleep -Milliseconds 800
    }

    Say '[run] starting client a (actor)'
    $clientA = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--nettest', '--connect', "127.0.0.1:$Port",
                        '--role', 'a', '--log', $logA) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'client-a.err')
    $null = $clientA.Handle

    $clientA.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    if ($clientB) { $clientB.WaitForExit($TimeoutSeconds * 1000) | Out-Null }

    $running = @(, @('a', $clientA))
    if ($clientB) { $running += , @('b', $clientB) }

    foreach ($pair in $running) {
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
    if ($clientB) { Show-Log 'CLIENT B (observer)' $logB }

    $clientLogs = @($logA)
    if ($clientB) { $clientLogs += $logB }

    $stuck = $false
    foreach ($path in $clientLogs) {
        if (Test-Path $path) {
            $text = Get-Content $path -Raw
            if ($text -notmatch 'NETTEST PASSED') {
                $failures += ((Split-Path -Leaf $path) + ' did not report NETTEST PASSED')
            }
            if ($text -notmatch 'the handshake completed over UDP') { $stuck = $true }
        } else {
            $failures += ((Split-Path -Leaf $path) + ' produced no output')
            $stuck = $true
        }
    }

    # netcheck passed and clients still cannot join. That narrows it a long way, and
    # saying so is worth more than the raw assertion failure: UDP works, the port
    # binds, and two ENet peers can shake hands, so the fault is above the transport.
    if ($stuck) {
        Rule
        Say 'A CLIENT NEVER COMPLETED THE HANDSHAKE, but netcheck passed.'
        Say 'So UDP works, the port binds, and two ENet peers can connect on this'
        Say 'machine. That rules out the firewall and rules out the ENet build.'
        Say 'Look at the join path: protocol version, access control refusing the'
        Say 'join, or the host being wedged. The server log above records every'
        Say 'refusal with its reason.'
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
