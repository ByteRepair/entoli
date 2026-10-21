#!/usr/bin/env bash
# Boots the browser's Linux in a headless Chromium and runs smoke_main.dart's
# commands through the real worker, image, 9p server and shell. Needs
# web/linux/image (build.sh), flutter, python3, and a Chromium; CHROMIUM names
# it where it is not chromium-browser's headless_shell.
set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
chromium=${CHROMIUM:-/usr/lib64/chromium-browser/headless_shell}
out="$root/build/web-linux-smoke"
port=${PORT:-8099}
server= browser=
profile=$(mktemp -d)
log=$(mktemp)
trap 'kill $browser $server 2>/dev/null; rm -rf "$profile" "$log"' EXIT

cd "$root"
flutter build web --release -t tool/web/linux/smoke_main.dart -o "$out" >/dev/null
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$out" >/dev/null 2>&1 &
server=$!
sleep 1

"$chromium" --headless --no-sandbox --user-data-dir="$profile" \
	--enable-logging=stderr --v=0 "http://127.0.0.1:$port/" 2>"$log" &
browser=$!
for _ in $(seq 1 "${TIMEOUT:-600}"); do
	grep -q "SMOKE done" "$log" && break
	kill -0 "$browser" 2>/dev/null || break
	sleep 1
done
grep -o '"SMOKE.*' "$log" | sed 's/^"SMOKE //; s/", source:.*$//'
if ! grep -q "SMOKE done" "$log"; then
	echo "--- did not finish; the console said:" >&2
	grep CONSOLE "$log" | tail -20 >&2
	exit 1
fi
