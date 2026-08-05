#!/bin/sh
# Release packaging for macOS and Linux — the POSIX half of package.ps1.
#
#   sh scripts/package.sh [project-dir]
#
# Stages the same ship list the Windows script does (engine + app + maps +
# meatgraphs, dev/authoring stripped), plus the optional project folder at
# project/ where the runtime auto-mounts it, and zips a .love. No fusing:
# on these platforms the .love IS the distributable — `love Game.love` —
# and every package manager ships LÖVE. A launcher script rides along so a
# double-click-ish path exists without one.
#
# The smoke check is a headless boot: the dedicated server runs the full
# boot path with no window, so "the archive is complete and loads" is
# verified on any machine with love installed — CI included.

set -e
cd "$(dirname "$0")/.."

PROJECT="$1"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
NAME="MeatRayCast"

if [ -n "$PROJECT" ]; then
    if [ ! -f "$PROJECT/project.json" ]; then
        echo "no project.json in $PROJECT" >&2
        exit 1
    fi
    # The project's name, crudely: good enough for a filename.
    NAME="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$PROJECT/project.json" | head -n 1 | tr -cd '[:alnum:]._-')"
    [ -n "$NAME" ] || NAME="game"
    PVERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$PROJECT/project.json" | head -n 1)"
    [ -n "$PVERSION" ] && VERSION="$PVERSION+engine.$VERSION"
fi

echo "Packaging $NAME $VERSION"

STAGE="build/stage-sh"
OUT="build"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"

# The ship list — keep in lockstep with package.ps1.
for f in main.lua conf.lua browse.lua netcheck.lua punchcheck.lua; do
    [ -f "$f" ] && cp "$f" "$STAGE/"
done
for d in meatray app maps meatgraphs; do
    cp -R "$d" "$STAGE/"
done
[ -n "$PROJECT" ] && cp -R "$PROJECT" "$STAGE/project"

# COMPILE=1 ships LuaJIT bytecode instead of readable source; ENCRYPT=1
# additionally seals each module (implies COMPILE). Both are deterrents, not
# locks — see docs/SHIPPING_SECURITY.md. The headless smoke below is the
# safety net: anything that makes a module unloadable fails the build.
[ "${ENCRYPT:-}" = "1" ] && COMPILE=1

# ENCRYPT: generate a key and inject the decrypting loader into conf.lua
# BEFORE compile, so the key rides inside conf.lua's own bytecode.
BOOTSTRAP="conf.lua main.lua meatray/net/crypto.lua meatray/pack/cryptoload.lua"
if [ "${ENCRYPT:-}" = "1" ]; then
    command -v luajit >/dev/null 2>&1 || { echo "ENCRYPT=1 needs luajit" >&2; exit 1; }
    KEYHEX="$(luajit -e "io.write(require('meatray.net.crypto').randomHex(32))")"
    [ "${#KEYHEX}" -eq 64 ] || { echo "could not generate a build key" >&2; exit 1; }
    {
        echo 'do'
        echo "    local key = require('meatray.net.crypto').fromHex('$KEYHEX')"
        echo "    require('meatray.pack.cryptoload').install(key)"
        echo 'end'
        cat "$STAGE/conf.lua"
    } > "$STAGE/conf.lua.new"
    mv -f "$STAGE/conf.lua.new" "$STAGE/conf.lua"
    echo "Encrypting modules (a build key is embedded in conf.lua)..."
fi

if [ "${COMPILE:-}" = "1" ]; then
    command -v luajit >/dev/null 2>&1 || { echo "COMPILE=1 needs luajit" >&2; exit 1; }
    echo "Compiling to bytecode (source will not ship)..."
    find "$STAGE" -type f -name '*.lua' | while read -r f; do
        luajit -b -s "$f" "$f.bc"
        mv -f "$f.bc" "$f"
    done
fi

if [ "${ENCRYPT:-}" = "1" ]; then
    find "$STAGE" -type f -name '*.lua' | while read -r f; do
        rel="${f#"$STAGE"/}"
        case " $BOOTSTRAP " in *" $rel "*) continue ;; esac   # keep as bytecode
        luajit scripts/sealfile.lua "$KEYHEX" "$f" "${f%.lua}.luac"
        rm -f "$f"
    done
fi

printf '%s' "$VERSION" > "$STAGE/VERSION"

# Same media scrub as the Windows script, project assets exempt.
find "$STAGE" -type f \( -name '*.png' -o -name '*.psd' -o -name '*.xcf' \
    -o -name '*.wav' -o -name '*.ogg' \) ! -path "$STAGE/project/*" -delete

LOVE_FILE="$OUT/$NAME-$VERSION.love"
rm -f "$LOVE_FILE"
# main.lua must sit at the ZIP ROOT, so zip from inside the stage.
( cd "$STAGE" && zip -q -r -9 "../../$LOVE_FILE" . )
echo "  .love: $LOVE_FILE ($(du -k "$LOVE_FILE" | cut -f1) KB)"

# MACAPP=1 assembles a macOS .app around the .love. The bundle is a directory
# with an Info.plist and the .love in Contents/Resources — LÖVE's own love.app
# runs a .love placed there. The only piece a non-Mac box cannot supply is the
# macOS `love` binary for Contents/MacOS/love: point LOVE_APP at a love.app to
# have it copied in, or drop it there on a Mac. Everything else is built here.
if [ "${MACAPP:-}" = "1" ]; then
    APP="$OUT/$NAME.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$LOVE_FILE" "$APP/Contents/Resources/$NAME.love"
    BUNDLE_ID="$(printf 'com.meatraycast.%s' "$NAME" | tr '[:upper:] ' '[:lower:]-')"
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>love</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
    if [ -n "${LOVE_APP:-}" ] && [ -f "$LOVE_APP/Contents/MacOS/love" ]; then
        cp "$LOVE_APP/Contents/MacOS/love" "$APP/Contents/MacOS/love"
        cp -R "$LOVE_APP/Contents/Frameworks" "$APP/Contents/" 2>/dev/null || true
        chmod +x "$APP/Contents/MacOS/love"
        echo "  .app: $APP (runnable — love binary copied from LOVE_APP)"
    else
        echo "  .app skeleton: $APP"
        echo "    -> drop a macOS love binary at Contents/MacOS/love (and its"
        echo "       Frameworks) to finish it, or set LOVE_APP=/path/to/love.app"
    fi
fi

# A launcher beside it, for people who unzip first and read second.
LAUNCH="$OUT/run-$NAME.sh"
{
    echo '#!/bin/sh'
    echo '# Requires LÖVE 11.x: https://love2d.org (apt/dnf/brew install love)'
    echo "exec love \"\$(dirname \"\$0\")/$NAME-$VERSION.love\" \"\$@\""
} > "$LAUNCH"
chmod +x "$LAUNCH"

# Smoke: the dedicated server exercises the whole boot path windowless.
if command -v love >/dev/null 2>&1; then
    echo "Smoke-booting headless..."
    LOG="$OUT/smoke-sh.log"
    love "$LOVE_FILE" --server --port 39999 --log "$LOG" &
    PID=$!
    sleep 5
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    if grep -q 'listening on UDP' "$LOG" 2>/dev/null; then
        echo "  SMOKE OK: booted and listened"
    else
        echo "  SMOKE FAILED — log:"
        cat "$LOG" 2>/dev/null
        exit 1
    fi
else
    echo "  (love not installed here — smoke skipped; the .love is untested)"
fi

echo "Release ready: $LOVE_FILE  (+ $LAUNCH)"
