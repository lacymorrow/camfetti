#!/bin/bash
cd "$(dirname "$0")"
for f in .run/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; trash "$f" 2>/dev/null || true; done
pkill -f 'ffmpeg.*127.0.0.1:8554' 2>/dev/null || true
echo "OK rig stopped"
