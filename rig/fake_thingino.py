#!/usr/bin/env python3
"""Fake Thingino web API for CamFetti tests. Mirrors the real endpoints the app uses:
POST /x/login.cgi, GET|POST /x/api-key.cgi, GET /x/json-config-rtsp.cgi,
POST /x/json-imp.cgi, GET /x/json-motor.cgi, GET /x/ch0.jpg, /x/ch1.jpg,
GET|POST /x/tool-record.cgi, GET /x/tool-sdcard.cgi, POST /x/json-prudynt.cgi (mp4 status/start/stop).
Root password: root. RTSP: thingino/thingino on :8554 (MediaMTX)."""
import base64, http.server, json, os, secrets, subprocess, sys, urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
STATE = {"sessions": set(), "api_key": None, "daynight": "day", "x": 1200, "y": 300, "log": [],
         "recorder": {"autostart": False, "channel": 0, "check_interval": 60, "cleanup_enabled": False,
                      "device_path": "%hostname", "duration": 60, "filename": "%Y/%m/%d/%H-%M-%S", "limit": 15,
                      "min_free_mb": 500, "mount": ""},
         "recording": False, "card_bytes": 31_914_983_424}
MOUNTS = ["/mnt/mmcblk0p1"]
HERE = os.path.dirname(os.path.abspath(__file__))

def snapshot(path):
    out = os.path.join(HERE, ".snap-%s.jpg" % path)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-rtsp_transport", "tcp", "-i",
                    "rtsp://thingino:thingino@127.0.0.1:8554/%s" % path, "-frames:v", "1", out], timeout=8)
    with open(out, "rb") as f:
        return f.read()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        STATE["log"].append(self.command + " " + self.path)
        sys.stderr.write("fake-thingino %s %s\n" % (self.command, self.path))

    def send(self, code, body, ctype="application/json", headers=()):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def session_ok(self):
        c = self.headers.get("Cookie", "")
        return any(("session=%s" % s) in c for s in STATE["sessions"])

    def authed(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        # Like a real Wyze v3 on Thingino: the X-API-Key header alone gets a 401, only token= works.
        key = (q.get("token") or [None])[0]
        return self.session_ok() or (key is not None and key == STATE["api_key"])

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        if u.path == "/":
            return self.send(200, b"<html><head><title>thingino</title></head></html>", "text/html")
        if u.path == "/x/api-key.cgi":
            if not self.session_ok():
                return self.send(401, {"error": "Session authentication required"})
            if STATE["api_key"]:
                return self.send(200, {"api_key": STATE["api_key"], "exists": True})
            return self.send(200, {"exists": False})
        if not self.authed():
            return self.send(401, {"error": "Authentication required. Use session cookie or X-API-Key header"})
        if u.path == "/x/json-config-rtsp.cgi":
            return self.send(200, {"username": "thingino", "password": "thingino", "onvif_port": "80",
                                   "rtsp_port": "8554", "rtsp_ch0": "ch0", "rtsp_ch1": "ch1", "rtsp_mic": "mic"})
        if u.path == "/x/json-motor.cgi":
            d = q.get("d", "j")
            if d in ("g", "h", "x"):
                STATE["x"] = max(0, min(2560, STATE["x"] + int(q.get("x", "0")) if d != "h" else int(q.get("x", "0"))))
                STATE["y"] = max(0, min(720, STATE["y"] + int(q.get("y", "0")) if d != "h" else int(q.get("y", "0"))))
            return self.send(200, {"code": 200, "result": "success",
                                   "message": {"status": "0", "xpos": STATE["x"], "ypos": STATE["y"]}})
        if u.path in ("/x/ch0.jpg", "/x/ch1.jpg", "/image.jpg"):
            return self.send(200, snapshot("ch1" if "ch1" in u.path else "ch0"), "image/jpeg")
        if u.path == "/_state":
            return self.send(200, {"daynight": STATE["daynight"], "x": STATE["x"], "y": STATE["y"], "log": STATE["log"][-50:],
                                   "recorder": STATE["recorder"], "recording": STATE["recording"]})
        if u.path == "/x/tool-record.cgi":
            return self.send(200, {"ok": True, "data": {"video": STATE["recorder"], "mounts": MOUNTS}})
        if u.path == "/x/tool-sdcard.cgi":
            present = STATE["card_bytes"] > 0
            return self.send(200, {"ok": True, "data": {"has_sdcard": present,
                                   "device": {"name": "mmcblk0", "size_bytes": STATE["card_bytes"]} if present else None,
                                   "reports": {"partitions_b64": base64.b64encode(
                                       b"Filesystem Size Used Available Use% Mounted on\n/dev/mmcblk0p1 29.7G 1.2G 28.5G 4% /mnt/mmcblk0p1\n").decode()}}})
        return self.send(404, {"error": "not found"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        raw = self.body()
        if u.path == "/x/login.cgi":
            try:
                d = json.loads(raw or "{}")
            except ValueError:
                return self.send(400, {"error": {"code": 400, "message": "bad json"}})
            pw = d.get("password", "")
            if d.get("encoding") == "base64":
                pw = base64.b64decode(pw).decode()
            if d.get("username") == "root" and pw == "root":
                sid = secrets.token_hex(16)
                STATE["sessions"].add(sid)
                return self.send(200, {"success": True, "is_default_password": True},
                                 headers=[("Set-Cookie", "session=%s; Path=/; HttpOnly; SameSite=Strict" % sid)])
            return self.send(401, {"error": {"code": 401, "message": "Invalid credentials"}})
        if u.path == "/x/api-key.cgi":
            if not self.session_ok():
                return self.send(401, {"error": "Session authentication required"})
            STATE["api_key"] = secrets.token_hex(32)
            return self.send(200, {"api_key": STATE["api_key"], "generated": True})
        if not self.authed():
            return self.send(401, {"error": "Authentication required. Use session cookie or X-API-Key header"})
        if u.path == "/x/json-imp.cgi":
            d = json.loads(raw or "{}")
            cmd, val = d.get("cmd"), d.get("val")
            if not cmd or val is None:
                return self.send(400, b"missing required parameter cmd", "text/plain")
            if cmd == "daynight":
                STATE["daynight"] = val
            elif cmd == "auto":
                STATE["daynight"] = "auto"
            return self.send(200, {"code": 200, "result": "success", "message": {"cmd": cmd, "val": val}})
        if u.path == "/x/tool-record.cgi":
            # Like the real CGI: every field comes from the form, an empty mount is rejected.
            f = {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}
            if f.get("form") != "video":
                return self.send(400, {"error": {"code": 400, "message": "Unsupported form submission"}})
            if not f.get("vr_mount"):
                return self.send(422, {"error": {"code": 422, "message": "Record mount cannot be empty."}})
            r = STATE["recorder"]
            r.update({"autostart": f.get("vr_autostart") == "true", "cleanup_enabled": f.get("vr_cleanup_enabled") == "true",
                      "channel": int(f.get("vr_channel", "0")), "device_path": f.get("vr_device_path", ""),
                      "duration": int(f.get("vr_duration", "60")), "filename": f.get("vr_filename", ""),
                      "limit": int(f.get("vr_limit", "15")), "min_free_mb": int(f.get("vr_min_free_mb", "500")),
                      "check_interval": int(f.get("vr_check_interval", "60")), "mount": f["vr_mount"]})
            return self.send(200, {"ok": True, "message": "Video recorder settings updated.",
                                   "data": {"video": r, "mounts": MOUNTS}})
        if u.path == "/x/json-prudynt.cgi":
            mp4 = json.loads(raw or "{}").get("mp4", {})
            if "status" in mp4:
                return self.send(200, {"mp4": {"status": {"ch0": STATE["recording"], "ch1": False}}})
            if "start" in mp4:
                if not STATE["recorder"]["mount"]:
                    return self.send(200, {"mp4": {"start": "mount path is empty"}})
                STATE["recording"] = True
                return self.send(200, {"mp4": {"start": "ok"}})
            if "stop" in mp4:
                STATE["recording"] = False
                return self.send(200, {"mp4": {"stop": "ok"}})
            return self.send(200, {})
        return self.send(404, {"error": "not found"})

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
