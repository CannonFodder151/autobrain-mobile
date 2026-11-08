#!/usr/bin/env bash
#
# Regression test for AUT-365: alpha track query race.
#
# The mock Play API returns an EMPTY alpha track for the first request, then
# a populated alpha track on subsequent requests. The promote script must
# retry/poll until the release is visible instead of failing immediately.
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/play-promote-to-production.sh"
PORT=18726
AAB="$(mktemp)"
LOG="$(mktemp)"
GOUT="$(mktemp)"
RSA_KEY="$(openssl genrsa 2048 2>/dev/null)"
fail() { echo "FAIL: $*" >&2; exit 1; }
trap 'rm -f "$AAB" "$LOG" "$GOUT"; [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null || true' EXIT
head -c 4096 /dev/zero > "$AAB"

MOCK_PID=""
python3 - "$PORT" "$LOG" <<'PY' &
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
port = int(sys.argv[1]); calls = sys.argv[2]
app = {"package":"com.autobrainservice.app","tracks":{"alpha":[],"production":[]},"edits":{},"n":0}
with open(calls,"w") as f: f.write("start\n")
def rec(m):
    with open(calls,"a") as f: f.write(m+"\n")
def next_eid():
    app["n"]+=1; return "edit-%d"%app["n"]
class H(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _json(self,code,obj):
        body=json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def _body(self): return json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))))
    def do_GET(self):
        p=urlparse(self.path); m=re.match(r"^/androidpublisher/v3/applications/[^/]+/tracks/([^/]+)/releases$",p.path)
        if m:
            t=m.group(1)
            if t=="alpha":
                # First alpha probe: empty (upload race). Subsequent: populated.
                if not app.get("_alpha_ready"):
                    app["_alpha_ready"] = True
                    rec("probe alpha -> EMPTY (race)")
                    return self._json(200,{"releases":[]})
                if not app["tracks"]["alpha"]:
                    app["tracks"]["alpha"].append({"versionCodes":["999"],"status":"completed"})
                rec("probe alpha -> populated")
                return self._json(200,{"releases":app["tracks"][t]})
            return self._json(200,{"releases":app["tracks"].get(t,[])})
        m=re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/tracks/([^/]+)$",p.path)
        if m:
            eid,track=m.group(1),m.group(2)
            if eid not in app["edits"]: return self._json(400,{"error":{"code":400,"message":"deleted","status":"FAILED_PRECONDITION"}})
            rel=app["tracks"].get(track,[])
            return self._json(200,{"track":track,"releases":rel})
        self._json(404,{"error":{"code":404}})
    def do_POST(self):
        p=urlparse(self.path)
        if p.path=="/token": return self._json(200,{"access_token":"fake-token"})
        m=re.match(r"^/androidpublisher/v3/applications/[^/]+/edits$",p.path)
        if m:
            eid=next_eid(); app["edits"][eid]=None; rec("insert %s"%eid)
            return self._json(200,{"id":eid,"expiryTimeSeconds":"9999999999"})
        m=re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/tracks$",p.path)
        if m:
            track=self._body().get("track")
            if track in app["tracks"]: return self._json(409,{"error":{"code":409,"message":"exists"}})
            app["tracks"][track]=[]; rec("track-create %s"%track); return self._json(200,{"track":track,"type":"PRODUCTION"})
        m=re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+):commit$",p.path)
        if m: return self._json(200,{})
        self._json(404,{"error":{"code":404}})
    def do_PUT(self):
        p=urlparse(self.path); m=re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/tracks/([^/]+)$",p.path)
        if m:
            body=self._body(); rel=body.get("releases")
            vc=rel[0].get("versionCodes",[]); st=rel[0].get("status","completed"); uf=rel[0].get("userFraction")
            app["tracks"].setdefault(m.group(2),[]).append({"versionCodes":vc,"status":st,"userFraction":uf})
            return self._json(200,{"track":m.group(2),"releases":rel})
        self._json(404,{"error":{"code":404}})
    def do_DELETE(self):
        p=urlparse(self.path); m=re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)$",p.path)
        if m: return self._json(200,{})
        self._json(404,{"error":{"code":404}})
srv=HTTPServer(("127.0.0.1",port),H); srv.serve_forever()
PY
MOCK_PID=$!; sleep 0.5
export PLAY_API_BASE="http://127.0.0.1:$PORT"
export GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(jq -n --arg email mock@example.com --arg uri "http://127.0.0.1:$PORT/token" --arg key "$RSA_KEY" '{client_email:$email,token_uri:$uri,private_key:$key}')"
export PLAY_PACKAGE_NAME="com.autobrainservice.app"
export PLAY_RELEASE_NOTES="mock promote retry"
export PLAY_SOURCE_POLL_ATTEMPTS=4
export PLAY_SOURCE_POLL_DELAY=0
out="$(bash "$SCRIPT" 2>&1)" || { echo "FAIL: $out"; exit 1; }
grep -q "probe alpha -> EMPTY (race)" "$LOG" || fail "first alpha probe should be empty (race)"
grep -q "probe alpha -> populated" "$LOG" || fail "second alpha probe should be populated (retry)"
grep -q "resolved versionCode 999 from 'alpha' (attempt 2/4)" <<<"$out" || fail "expected retry resolution: $out"
grep -q "pre-flight OK" <<<"$out" || fail "preflight failed"
grep -q "production release OK" <<<"$out" || fail "production commit failed"
grep -q "staged rollout" <<<"$out" || fail "expected staged rollout message (AUT-322)"
echo "OK promote-to-production retry (AUT-365)"