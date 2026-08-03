# Both-interpreters test lane.
#
# The whole suite runs under LuaJIT (the shipping interpreter) AND plain Lua
# 5.4, and this script fails if either does. The second lane exists because
# the two runtimes disagree in exactly the places that bite quietly: Lua 5.4
# has integer subtypes (a `sign * 0` there is integer arithmetic with no
# signed zero), and it has no FFI (so every FFI-first path must genuinely
# fall back). Both of those were shipped bugs found by running plain Lua by
# hand; this makes that run a habit instead of an accident.
#
#   powershell -ExecutionPolicy Bypass -File scripts\suite.ps1
#   ... -SkipPlain     # LuaJIT only, when plain lua is not installed
#
# Exit 0 only when every requested lane passed.

param(
    [string]$LuaJit = 'luajit',
    [string]$Lua = 'lua',
    [switch]$SkipPlain
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$failed = @()

function Run-Lane([string]$name, [string]$exe) {
    Write-Host "=== $name ($exe) ===" -ForegroundColor Cyan
    & $exe tests/run_all.lua
    if ($LASTEXITCODE -ne 0) {
        $script:failed += $name
        Write-Host "$name FAILED" -ForegroundColor Red
    } else {
        Write-Host "$name passed" -ForegroundColor Green
    }
}

Run-Lane 'luajit' $LuaJit

if (-not $SkipPlain) {
    if (Get-Command $Lua -ErrorAction SilentlyContinue) {
        Run-Lane 'plain-lua' $Lua
    } else {
        # Absent is reported, not silently skipped: a lane that quietly
        # vanishes is how the plain-Lua bugs got shipped the first time.
        Write-Host "plain lua ('$Lua') not found - lane NOT run (use -SkipPlain to accept)" -ForegroundColor Yellow
        $failed += 'plain-lua (interpreter missing)'
    }
}

Write-Host ('=' * 58)
if ($failed.Count -gt 0) {
    Write-Host ("SUITE LANES FAILED: " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL LANES PASSED' -ForegroundColor Green
exit 0
