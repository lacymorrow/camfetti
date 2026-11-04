#!/usr/bin/env python3
"""Prints the `-seedReal <base64>` launch argument for the cameras saved by
shots-save-camera-logins.sh. The value carries passwords: pass it straight to
`simctl launch` or the app, never echo it. Debug builds only read it."""
import base64, json, re, subprocess, sys

NAMES = ["Front of House", "Back of House", "Driveway", "Wyze"]
LABELS = {"Wyze": "Library"}  # the Wyze watches a miniature book nook, not a real room
items = []
for name in NAMES:
    meta = subprocess.run(["security", "find-generic-password", "-s", "camfetti-shots", "-a", name],
                          capture_output=True, text=True)
    if meta.returncode != 0:
        continue
    m = re.search(r'"icmt"<blob>="([^"]*)"', meta.stdout)
    if not m:
        continue
    address, user = m.group(1).split("|", 1)
    pw = subprocess.run(["security", "find-generic-password", "-s", "camfetti-shots", "-a", name, "-w"],
                        capture_output=True, text=True).stdout.rstrip("\n")
    items.append({"name": LABELS.get(name, name), "address": address, "user": user, "pass": pw})
if not items:
    sys.exit("no camera logins saved; run scripts/shots-save-camera-logins.sh first")
sys.stdout.write(base64.b64encode(json.dumps(items).encode()).decode())
