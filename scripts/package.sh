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

printf '%s' "$VERSION" > "$STAGE/VERSION"

# Same media scrub as the Windows script, project assets exempt.
find "$STAGE" -type f \( -name '*.png' -o -name '*.psd' -o -name '*.xcf' \
    -o -name '*.wav' -o -name '*.ogg' \) ! -path "$STAGE/project/*" -delete

LOVE_FILE="$OUT/$NAME-$VERSION.love"
rm -f "$LOVE_FILE"
# main.lua must sit at the ZIP ROOT, so zip from inside the stage.
( cd "$STAGE" && zip -q -r -9 "../../$LOVE_FILE" . )
echo "  .love: $LOVE_FILE ($(du -k "$LOVE_FILE" | cut -f1) KB)"

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
