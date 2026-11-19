#!/bin/sh
# Build claub-mac-voice and run it at login as a LaunchAgent (label claub-mac-voice).
#   ./install.sh [port]      install or update (default port 10301), then start it
#   ./install.sh uninstall   stop it and remove the LaunchAgent and binary
set -eu
cd "$(dirname "$0")"
label=claub-mac-voice
agent="$HOME/Library/LaunchAgents/$label.plist"
binary="$HOME/.local/bin/claub-mac-voice"
log="$HOME/Library/Logs/claub-mac-voice.log"
domain="gui/$(id -u)"

if [ "${1:-}" = uninstall ]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$agent" "$binary"
    echo "removed $label"
    exit 0
fi
port="${1:-10301}"
case "$port" in
    ''|*[!0-9]*) echo "usage: $0 [port] | uninstall   (not: $port)" >&2; exit 2 ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "usage: $0 [port] | uninstall   (port must be 1-65535)" >&2
    exit 2
fi

swift build -c release
mkdir -p "$(dirname "$binary")" "$(dirname "$agent")" "$(dirname "$log")"
launchctl bootout "$domain/$label" 2>/dev/null || true
cp .build/release/claub-mac-voice "$binary"
sed -e "s|BINARY|$binary|" -e "s|PORT|$port|" -e "s|LOG|$log|" launchd/claub-mac-voice.plist > "$agent"
# bootout can return before the old job is gone, and bootstrap fails until it is.
attempt=1
until launchctl bootstrap "$domain" "$agent" 2>/dev/null; do
    if [ "$attempt" -ge 10 ]; then
        launchctl bootstrap "$domain" "$agent"  # show the error
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS "http://127.0.0.1:$port/health" 2>/dev/null; then
        echo
        echo "$label is running on ws://127.0.0.1:$port (log: $log)"
        exit 0
    fi
    sleep 1
done
echo "$label did not answer on port $port; see $log" >&2
exit 1
