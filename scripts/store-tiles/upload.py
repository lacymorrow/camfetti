#!/usr/bin/env python3
"""Replaces one App Store screenshot set (or preview set) on a draft version with local files.
Usage: upload.py <versionId> shots <DISPLAY_TYPE> files...   |   upload.py <versionId> preview <PREVIEW_TYPE> file.mp4
Uses ~/.appstoreconnect/asc.py for auth."""
import hashlib, json, os, subprocess, sys, time, urllib.request

def asc(m, p, b=None):
    a = ["python3", os.path.expanduser("~/.appstoreconnect/asc.py"), m, p] + ([json.dumps(b)] if b else [])
    o = subprocess.run(a, capture_output=True, text=True).stdout
    s, _, body = o.partition("\n")
    return int(s), (json.loads(body) if body.strip() else {})

def put_parts(ops, data):
    for op in ops:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"],
                                     headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        urllib.request.urlopen(req).read()

version, kind, display, *files = sys.argv[1:]
s, locs = asc("GET", f"/v1/appStoreVersions/{version}/appStoreVersionLocalizations")
loc = next(l for l in locs["data"] if l["attributes"]["locale"] == "en-US")["id"]
coll, attr, item, rel = (("appScreenshotSets", "screenshotDisplayType", "appScreenshots", "appScreenshotSet") if kind == "shots"
                         else ("appPreviewSets", "previewType", "appPreviews", "appPreviewSet"))
s, sets = asc("GET", f"/v1/appStoreVersionLocalizations/{loc}/{coll}")
match = [x for x in sets["data"] if x["attributes"][attr] == display]
if match:
    set_id = match[0]["id"]
    s, old = asc("GET", f"/v1/{coll}/{set_id}/{item}")
    for o in old["data"]:
        print("delete", o["id"], asc("DELETE", f"/v1/{item}/{o['id']}")[0])
else:
    s, r = asc("POST", f"/v1/{coll}", {"data": {"type": coll, "attributes": {attr: display},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc}}}}})
    set_id = r["data"]["id"]
ids = []
for f in files:
    data = open(f, "rb").read()
    attrs = {"fileName": os.path.basename(f), "fileSize": len(data)}
    if kind == "preview":
        attrs["previewFrameTimeCode"] = "00:00:03:00"
        attrs["mimeType"] = "video/mp4"
    s, r = asc("POST", f"/v1/{item}", {"data": {"type": item, "attributes": attrs,
        "relationships": {rel: {"data": {"type": coll, "id": set_id}}}}})
    if s != 201:
        sys.exit(f"reserve failed {s} {r}")
    put_parts(r["data"]["attributes"]["uploadOperations"], data)
    s, r = asc("PATCH", f"/v1/{item}/{r['data']['id']}", {"data": {"type": item, "id": r["data"]["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print("uploaded", os.path.basename(f), s)
    ids.append(r["data"]["id"])
if kind == "shots":
    print("order", asc("PATCH", f"/v1/{coll}/{set_id}/relationships/{item}", {"data": [{"type": item, "id": i} for i in ids]})[0])
