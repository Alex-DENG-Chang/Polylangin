#!/bin/sh
# Keep the Polylangin IBus engine process alive.
# IBus' component spawning does not work reliably with a python3+args exec line,
# so the engine is pre-started at login instead; ibus-daemon then connects to the
# already-running bus name.
INSTALL="$HOME/.local/share/polylangin"
mkdir -p "$INSTALL/logs"
while true; do
  python3 "$INSTALL/polylangin_ibus.py" >> "$INSTALL/logs/engine.out" 2>&1
  sleep 2
done
