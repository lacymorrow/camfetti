#!/usr/bin/env python3
"""Fake Reolink HTTP API for CamFetti tests: POST /cgi-bin/api.cgi with Login, Logout, GetDevInfo, GetHddInfo,
GetRecV20/SetRecV20 (newer firmware, like an RLC-510A) or GetRec/SetRec (2020 firmware, like an RLC-410), Search.
Usage: fake_reolink.py <port> [v20|legacy|nocard|locked]. Password: thingino. Recording starts off with an empty schedule,
except "locked": 2020 firmware, recording on, and SetRec refused with -26 like a real RLC-410 with a non-admin account.
GET /state shows what the app saved."""
import http.server, json, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8081
KIND = sys.argv[2] if len(sys.argv) > 2 else "v20"
ZEROS = "0" * 168
STATE = {"v20": {"enable": 0, "overwrite": 0, "postRec": "15 Seconds", "preRec": 1,
                 "schedule": {"channel": 0, "table": {"AI_PEOPLE": ZEROS, "AI_VEHICLE": ZEROS, "MD": ZEROS, "TIMING": ZEROS}}},
         "legacy": {"channel": 0, "overwrite": 0, "postRec": "15 Seconds", "preRec": 1, "schedule": {"enable": 0, "table": ZEROS}},
         "logins": 0, "bad_logins": 0}
if KIND == "locked":
    STATE["legacy"]["schedule"] = {"enable": 1, "table": "1" * 168}
    STATE["legacy"]["overwrite"] = 1

def reply(cmd, value=None, code=0, error=None):
    r = {"cmd": cmd, "code": code}
    if value is not None: r["value"] = value
    if error: r["error"] = error
    return r

def unsupported(): return reply("Unknown", code=1, error={"detail": "not support", "rspCode": -9})

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *a): sys.stderr.write("fake-reolink %s %s\n" % (self.command, self.path))

    def send(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/state": return self.send(STATE)
        self.send_response(404); self.end_headers()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"[]")
        out = []
        for c in body:
            cmd, param = c.get("cmd"), c.get("param", {})
            if cmd == "Login":
                if param.get("User", {}).get("password") != "thingino":
                    STATE["bad_logins"] += 1
                    out.append(reply(cmd, code=1, error={"detail": "login failed", "rspCode": -7}))
                else:
                    STATE["logins"] += 1
                    out.append(reply(cmd, {"Token": {"leaseTime": 3600, "name": "rigtoken"}}))
            elif cmd in ("Logout", "GetDevInfo"):
                out.append(reply(cmd, {"DevInfo": {"model": "RLC-510A" if KIND in ("v20", "nocard") else "RLC-410-5MP"}} if cmd == "GetDevInfo" else {"rspCode": 200}))
            elif cmd == "GetHddInfo":
                disks = [] if KIND == "nocard" else [{"capacity": 30524, "format": 1, "mount": 1, "number": 0, "size": 400, "storageType": 2}]
                out.append(reply(cmd, {"HddInfo": disks}))
            elif cmd == "GetRecV20":
                out.append(reply(cmd, {"Rec": STATE["v20"]}) if KIND in ("v20", "nocard") else unsupported())
            elif cmd == "SetRecV20" and KIND in ("v20", "nocard"):
                STATE["v20"] = param["Rec"]; out.append(reply(cmd, {"rspCode": 200}))
            elif cmd == "GetRec":
                out.append(reply(cmd, {"Rec": STATE["legacy"]}))
            elif cmd == "SetRec" and KIND == "locked":
                out.append(reply(cmd, code=1, error={"detail": "ability error", "rspCode": -26}))
            elif cmd == "SetRec":
                STATE["legacy"] = param["Rec"]; out.append(reply(cmd, {"rspCode": 200}))
            elif cmd == "Search":
                out.append(reply(cmd, {"SearchResult": {"channel": 0, "Status": []}}))
            else:
                out.append(unsupported())
        self.send(out)

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
