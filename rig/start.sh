#!/bin/bash
# Start the CamFetti test rig: MediaMTX fake cameras on :8554, fake Thingino API on :8080,
# fake Reolink APIs on :8081-8084, and Bonjour adverts so the app discovers "Rig Porch" like a real Thingino camera.
# Stop with ./stop.sh
set -euo pipefail
cd "$(dirname "$0")"
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
mkdir -p .run
nohup mediamtx mediamtx.yml > .run/mediamtx.log 2>&1 & echo $! > .run/mediamtx.pid
nohup python3 fake_thingino.py 8080 > .run/thingino.log 2>&1 & echo $! > .run/thingino.pid
nohup python3 fake_reolink.py 8081 v20 > .run/reolink.log 2>&1 & echo $! > .run/reolink.pid
nohup python3 fake_reolink.py 8082 legacy > .run/reolink-old.log 2>&1 & echo $! > .run/reolink-old.pid
nohup python3 fake_reolink.py 8083 locked > .run/reolink-locked.log 2>&1 & echo $! > .run/reolink-locked.pid
nohup python3 fake_reolink.py 8084 nocard > .run/reolink-nocard.log 2>&1 & echo $! > .run/reolink-nocard.pid
nohup dns-sd -P "Rig Porch" _thingino._tcp local 8080 rig-porch.local "$IP" product=wyze_cam3_t31x_gc2053 version=2026-10-30 streamer=prudynt > .run/mdns1.log 2>&1 & echo $! > .run/mdns1.pid
nohup dns-sd -P "Rig Porch" _rtsp._tcp local 8554 rig-porch.local "$IP" > .run/mdns2.log 2>&1 & echo $! > .run/mdns2.pid
echo "OK rig on $IP: rtsp://thingino:thingino@$IP:8554/{ch0,ch1,hevc}  thingino api http://$IP:8080 (root/root)  reolink api :8081 new firmware, :8082 2020 firmware, :8083 refuses changes, :8084 no card (password thingino)"
