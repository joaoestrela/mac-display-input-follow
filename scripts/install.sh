#!/bin/sh
# Installs a release build: the binary to ~/.local/bin and a login item that runs it.
# Run from the unpacked release folder, while each monitor shows this Mac:
#   ./install.sh
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
bindir="${BINDIR:-$HOME/.local/bin}"
label="${LABEL:-com.joaoestrela.display-follow}"
plist="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/display-follow.log"
domain="gui/$(id -u)"

xattr -d com.apple.quarantine "$here/display-follow" 2>/dev/null || true
mkdir -p "$bindir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$here/display-follow" "$bindir/display-follow"
sed -e "s#@LABEL@#$label#" -e "s#@BINDIR@#$bindir#" -e "s#@LOG@#$logfile#" \
    "$here/com.display-follow.plist.in" > "$plist"
plutil -lint "$plist" >/dev/null

config="${XDG_CONFIG_HOME:-$HOME/.config}/display-follow/config.json"
[ -f "$config" ] || "$bindir/display-follow" setup

launchctl bootout "$domain/$label" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "$domain/$label" >/dev/null 2>&1 || break; sleep 0.5; done
launchctl bootstrap "$domain" "$plist"
echo "installed $bindir/display-follow; log: $logfile"
echo "to remove: launchctl bootout $domain/$label && rm $plist $bindir/display-follow"
