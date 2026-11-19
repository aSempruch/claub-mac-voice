#!/bin/sh
# Build claub-mac-voice and run it at login as a LaunchAgent (label claub-mac-voice); also, for Claub on a
# dev box, the voice link relay and the ssh tunnel it runs through, as LaunchAgents of their own.
#   ./install.sh [port]                      install or update the voice server (default port 10301), start it
#   ./install.sh --link [--token-file PATH]  install or update the voice link relay (com.claub.voice-link);
#                                            the token defaults to ~/.config/claub/voice-link.token
#   ./install.sh --tunnel HOST               install or update the ssh tunnel to HOST (com.claub.tunnel)
#   ./install.sh uninstall                   stop all of them and remove what this script installed
# --link and --tunnel can be given together; they leave the voice server as it is.
set -eu
domain="gui/$(id -u)"
agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs"
label=claub-mac-voice
binary="$HOME/.local/bin/claub-mac-voice"
log="$logs/claub-mac-voice.log"
link_label=com.claub.voice-link
link_dir="$HOME/.local/share/claub-mac-voice/link"
link_log="$logs/claub-voice-link.log"
tunnel_label=com.claub.tunnel
tunnel_log="$logs/claub-tunnel.log"
usage="usage: $0 [port] | --link [--token-file PATH] [--tunnel HOST] | --tunnel HOST | uninstall"

bad() { echo "$usage   ($*)" >&2; exit 2; }
fail() { echo "$*" >&2; exit 1; }

# bootout can return before the old job is gone, and bootstrap fails until it is.
bootstrap() {
    attempt=1
    until launchctl bootstrap "$domain" "$agents/$1.plist" 2>/dev/null; do
        if [ "$attempt" -ge 10 ]; then
            launchctl bootstrap "$domain" "$agents/$1.plist"  # show the error
            exit 1
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
}

# A LaunchAgent from launchd/LABEL.plist with its @NAME@ placeholders filled in, (re)loaded.
install_agent() {
    agent_label="$1"
    shift
    launchctl bootout "$domain/$agent_label" 2>/dev/null || true
    mkdir -p "$agents" "$logs"
    sed "$@" "launchd/$agent_label.plist" > "$agents/$agent_label.plist"
    bootstrap "$agent_label"
}

if [ "${1:-}" = uninstall ] && [ $# -eq 1 ]; then
    for each in "$label" "$link_label" "$tunnel_label"; do
        launchctl bootout "$domain/$each" 2>/dev/null || true
        rm -f "$agents/$each.plist"
    done
    rm -f "$binary"
    rm -rf "$link_dir"
    echo "removed $label, $link_label and $tunnel_label"
    exit 0
fi

link=0
token="$HOME/.config/claub/voice-link.token"
token_given=0
host=""
port=""
while [ $# -gt 0 ]; do
    case "$1" in
        --link) link=1 ;;
        --token-file)
            [ $# -ge 2 ] || bad "--token-file needs a path"
            token="$2"; token_given=1; shift ;;
        --tunnel)
            [ $# -ge 2 ] || bad "--tunnel needs a host"
            host="$2"; shift
            case "$host" in
                ''|-*|*[!A-Za-z0-9@._:%+-]*) bad "not an ssh host: $host" ;;
            esac ;;
        *)
            [ -z "$port" ] || bad "one port only"
            port="$1" ;;
    esac
    shift
done
[ "$token_given" -eq 0 ] || [ "$link" -eq 1 ] || bad "--token-file goes with --link"

if [ "$link" -eq 1 ] || [ -n "$host" ]; then
    [ -z "$port" ] || bad "a port is for the voice server alone: $port"
    if [ "$link" -eq 1 ]; then
        uv="$(command -v uv || true)"
        [ -n "$uv" ] || uv="$HOME/.local/bin/uv"
        [ -x "$uv" ] || fail "uv is not installed: see https://docs.astral.sh/uv/ (the relay runs with uv run)"
        case "$token" in /*) ;; *) token="$PWD/$token" ;; esac
        case "$token" in *[\|\&\<\>]*) bad "a token path without | & < >: $token" ;; esac
        [ -f "$token" ] || fail "no token file at $token: copy ~/.claub/data/voice-link.token from the dev box there, then chmod 600 it"
        [ -s "$token" ] || fail "$token is empty: copy ~/.claub/data/voice-link.token from the dev box again"
        mode="$(stat -f %Lp "$token")"
        [ "$mode" = 600 ] || fail "$token has mode $mode: chmod 600 it (it is the key to Claub's voice link)"
    fi
    cd "$(dirname "$0")"
    installed=""
    if [ -n "$host" ]; then
        installed="$tunnel_label"
        install_agent "$tunnel_label" -e "s|@HOST@|$host|" -e "s|@LOG@|$tunnel_log|"
        echo "$tunnel_label: ssh -L 9420:127.0.0.1:9420 $host (log: $tunnel_log)"
    fi
    if [ "$link" -eq 1 ]; then
        installed="$installed $link_label"
        mkdir -p "$link_dir"
        cp link/claub_voice_link.py link/voice_link_wire.py "$link_dir/"
        "$uv" run --quiet "$link_dir/claub_voice_link.py" --help > /dev/null  # fetch aiohttp now, not at login
        install_agent "$link_label" -e "s|@UV@|$uv|" -e "s|@SCRIPT@|$link_dir/claub_voice_link.py|" \
            -e "s|@TOKEN@|$token|" -e "s|@LOG@|$link_log|"
        echo "$link_label: the voice link relay, token $token (log: $link_log)"
    fi
    sleep 2
    for each in $installed; do
        if launchctl print "$domain/$each" 2>/dev/null | grep -q "state = running"; then
            echo "$each is running"
        else
            fail "$each is not running (launchd keeps starting it again); see its log in $logs"
        fi
    done
    exit 0
fi

port="${port:-10301}"
case "$port" in
    ''|*[!0-9]*) bad "not a port: $port" ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    bad "port must be 1-65535"
fi

cd "$(dirname "$0")"
swift build -c release
mkdir -p "$(dirname "$binary")"
launchctl bootout "$domain/$label" 2>/dev/null || true
cp .build/release/claub-mac-voice "$binary"
install_agent "$label" -e "s|BINARY|$binary|" -e "s|PORT|$port|" -e "s|LOG|$log|"
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
