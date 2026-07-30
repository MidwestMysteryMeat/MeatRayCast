# The snapshot stream, measured on real sockets.
#
#   powershell -ExecutionPolicy Bypass -File scripts\netfrag.ps1
#   ... -Loss 0.2 -Seconds 30 -SmallFillers 28 -LargeFillers 120 -KeepLogs
#
# Three OS processes per run: a headless dedicated server, a UDP relay that
# throws away a fraction of the datagrams going downstream, and a probe that
# joins through the relay and counts what arrives. Five runs:
#
#   clean-small   under MTU_SAFE_BYTES, no loss   -- the baseline
#   lossy-under   under MTU_SAFE_BYTES, loss      -- is the stream unreliable?
#   lossy-over    over  MTU_SAFE_BYTES, loss      -- and one entity later?
#   clean-large   far over,             no loss   -- does it fragment at all?
#   lossy-large   far over,             loss      -- what does ENet do with them?
#
# `lossy-under` and `lossy-over` are the pair the exercise is for. On the arena
# map the entity counts differ by two and the snapshot by well under a hundred
# bytes, but one is inside a single datagram and the other is not. If a
# fragmented unreliable packet really is promoted to reliable, `lossy-over`
# delivers ~100% of the snapshots the host sent -- every loss retransmitted --
# while `lossy-under` delivers ~(1 - loss). If instead ENet dropped them
# properly, `lossy-over` delivers (1 - loss)^fragments, which is *lower* than
# `lossy-under`, not higher. The two hypotheses predict opposite directions, so
# the result is readable without trusting either.
#
# The filler counts are calibrated, not guessed: on maps/arena.map a snapshot
# costs about 43 bytes per replicated entity, so 26 entities is 1343 bytes and 28
# is 1429. Changing the map or adding a component with netFields moves that line,
# which is why the probe is told `--expect under|over` rather than working it out.
#
# Every run goes through the relay, including the clean ones, so the path is the
# same and loss is the only variable.
#
# Exit 0 when every probe passed its own assertions. The interesting numbers are
# printed regardless: the probe asserts sizes and fidelity, it does not assert
# which delivery mode ENet chose, because that is the thing being measured.

param(
    [int]$Port = 6789,
    [int]$ProxyPort = 6800,
    [string]$Love = 'F:\LOVE\lovec.exe',
    [string]$Map = 'arena',
    [double]$Loss = 0.2,
    [int]$Seconds = 25,
    [int]$SmallFillers = 16,
    [int]$UnderFillers = 18,
    [int]$OverFillers = 20,
    [int]$LargeFillers = 120,
    [int]$Seed = 20260730,
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $env:TEMP ('meatray-netfrag-' + $PID)
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Say($text) { Write-Host $text }
function Rule { Write-Host ('=' * 72) }

function Kill-Strays {
    Get-Process -Name 'lovec', 'love' -ErrorAction SilentlyContinue |
        ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
}

function Show-Log($title, $path) {
    Rule; Say $title; Rule
    if (Test-Path $path) { Get-Content $path | ForEach-Object { Write-Host $_ } }
    else { Say '(no output)' }
}

# Waits for a pattern to appear in a log, with a stated budget, and says how long
# it actually took. A fixed sleep that is long enough here is a race elsewhere,
# and a wait that was too short has already been misread in this repo as a
# blocked port.
function Wait-ForLine($path, $pattern, $budgetSeconds, $what) {
    $deadline = (Get-Date).AddSeconds($budgetSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            $text = Get-Content $path -Raw -ErrorAction SilentlyContinue
            if ($text -and $text -match $pattern) {
                $spent = $budgetSeconds - ($deadline - (Get-Date)).TotalSeconds
                Say ("[run] $what after {0:N1} s of a $budgetSeconds s budget" -f $spent)
                return $true
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Say "[run] $what NEVER HAPPENED within its $budgetSeconds s budget"
    return $false
}

$failures = @()
$summary = @()

function Run-Case($label, $fillers, $lossFraction, $expect) {
    $serverLog = Join-Path $logDir "$label-server.log"
    $proxyLog  = Join-Path $logDir "$label-proxy.log"
    $probeLog  = Join-Path $logDir "$label-probe.log"

    Rule
    Say "[case] $label : $fillers fillers, loss $lossFraction, expect $expect, $Seconds s window"
    Rule

    Kill-Strays
    Start-Sleep -Milliseconds 400

    # ------------------------------------------------------------------ host
    $serverArgs = @('.', '--server', '--port', "$Port", '--map', $Map,
                    '--name', "netfrag-$label", '--no-lan', '--log', $serverLog)
    if ($fillers -gt 0) { $serverArgs += @('--fillers', "$fillers") }

    $server = Start-Process -FilePath $Love -ArgumentList $serverArgs `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir "$label-server.err")
    $null = $server.Handle

    if (-not (Wait-ForLine $serverLog "listening on UDP $Port" 60 'the server was listening')) {
        $script:failures += "$label : the server never came up"
        Show-Log "SERVER ($label)" $serverLog
        return
    }

    # ----------------------------------------------------------------- relay
    # Budget generously: the probe needs join + warm-up + window + four stats
    # round trips, and a relay that stops early looks exactly like a link that
    # died.
    $proxySeconds = $Seconds + 20

    $proxy = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--netproxy', '--port', "$ProxyPort",
                        '--bind', '127.0.0.1', '--forward', "127.0.0.1:$Port",
                        '--loss', "$lossFraction", '--drop', 'down',
                        '--grace', '3', '--seed', "$Seed",
                        '--seconds', "$proxySeconds", '--log', $proxyLog) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir "$label-proxy.err")
    $null = $proxy.Handle

    if (-not (Wait-ForLine $proxyLog 'forwarding to' 30 'the relay was bound')) {
        $script:failures += "$label : the relay never bound"
        Show-Log "RELAY ($label)" $proxyLog
        return
    }

    # ----------------------------------------------------------------- probe
    $probe = Start-Process -FilePath $Love `
        -ArgumentList @('.', '--netfrag', '--connect', "127.0.0.1:$ProxyPort",
                        '--fillers', "$fillers", '--seconds', "$Seconds",
                        '--expect', $expect,
                        '--warmup', '4', '--label', $label, '--log', $probeLog) `
        -WorkingDirectory $root -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir "$label-probe.err")
    $null = $probe.Handle

    $probeBudget = ($Seconds + 120) * 1000
    $probe.WaitForExit($probeBudget) | Out-Null
    if (-not $probe.HasExited) {
        $script:failures += "$label : the probe timed out after $($probeBudget / 1000) s"
        try { Stop-Process -Id $probe.Id -Force } catch {}
    } elseif ($probe.ExitCode -ne 0) {
        $script:failures += "$label : the probe exited $($probe.ExitCode)"
    }

    # Let the relay finish its own budget so its totals cover the whole run.
    $proxy.WaitForExit(($proxySeconds + 30) * 1000) | Out-Null
    if (-not $proxy.HasExited) { try { Stop-Process -Id $proxy.Id -Force } catch {} }

    try { Stop-Process -Id $server.Id -Force } catch {}

    Show-Log "PROBE ($label)" $probeLog
    Show-Log "RELAY ($label)" $proxyLog

    if (Test-Path $probeLog) {
        $text = Get-Content $probeLog -Raw
        $m = [regex]::Match($text, 'RESULT .*')
        if ($m.Success) { $script:summary += $m.Value }
        if ($text -notmatch 'NETFRAG PASSED') {
            $script:failures += "$label : the probe did not report NETFRAG PASSED"
        }
    } else {
        $script:failures += "$label : the probe produced no output"
    }
    if (Test-Path $proxyLog) {
        $text = Get-Content $proxyLog -Raw
        $m = [regex]::Match($text, '\[proxy\] host -> client: .*')
        if ($m.Success) { $script:summary += ("  relay " + $label + ": " + $m.Value) }
        $m2 = [regex]::Match($text, '\[proxy\] downstream datagram rate .*')
        if ($m2.Success) { $script:summary += ("  relay " + $label + ": " + $m2.Value) }
    }
}

try {
    Say 'MeatRayCast snapshot-stream measurement over real UDP'
    Say "  love      : $Love"
    Say "  project   : $root"
    Say "  host port : $Port   relay port: $ProxyPort   map: $Map"
    Say "  loss      : $Loss (downstream only)   window: $Seconds s   seed: $Seed"
    Say "  logs      : $logDir"

    if (-not (Test-Path $Love)) { throw "LOVE not found at $Love" }

    Run-Case 'clean-small' $SmallFillers 0.0   'under'
    Run-Case 'lossy-under' $UnderFillers $Loss 'under'
    Run-Case 'lossy-over'  $OverFillers  $Loss 'over'
    Run-Case 'clean-large' $LargeFillers 0.0   'over'
    Run-Case 'lossy-large' $LargeFillers $Loss 'over'
}
finally {
    Kill-Strays
    Rule
    Say 'SUMMARY'
    Rule
    $summary | ForEach-Object { Say $_ }
    Rule
    if ($failures.Count -eq 0) {
        Say 'NETFRAG SUITE PASSED'
        if (-not $KeepLogs) { Remove-Item -Recurse -Force $logDir -ErrorAction SilentlyContinue }
        else { Say "logs kept at: $logDir" }
        exit 0
    } else {
        Say 'NETFRAG SUITE FAILED'
        $failures | ForEach-Object { Say ('  - ' + $_) }
        Say "logs kept at: $logDir"
        exit 1
    }
}
