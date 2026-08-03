# scripts/lint.ps1 — run luacheck the way CI does.
#
# The lint gate exists for one bug class above all: a `local function` that
# references a name defined LATER in the file resolves to a nil GLOBAL, and
# nothing fails until that path runs. Luacheck flags it as an undefined global.
# Shipping code (meatray/, main.lua, the tools) is strict; tests and dev scripts
# get the latitude their idioms need. See .luacheckrc.
#
#   powershell -File scripts\lint.ps1

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$lc = Get-Command luacheck -ErrorAction SilentlyContinue
if (-not $lc) {
    Write-Host "luacheck not found on PATH." -ForegroundColor Yellow
    Write-Host "Install it with:  luarocks install luacheck"
    exit 2
}

& luacheck meatray main.lua conf.lua scripts browse.lua masterserver relayserver relaycheck tests
exit $LASTEXITCODE
