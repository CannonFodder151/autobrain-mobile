#!/usr/bin/env bash
#
# Self-check for scripts/play-upload-closed-testing.sh against a local mock of
# the AndroidPublisher API. Faithfully reproduces the AUT-952 failure mode:
# Play silently deletes the previously-open edit when a second edits.insert
# lands, so the old "probe edit" flow died with 400 "This Edit has been
# deleted" on the bundle upload. The fixed script keeps a single edit open and
# passes all scenarios.
#
# Run: bash scripts/play-upload-closed-testing.test.sh
# Requires: bash, python3, curl, jq, openssl.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/play-upload-closed-testing.sh"
PORT="${PLAY_MOCK_PORT:-18723}"
AAB="$(mktemp)"
LOG="$(mktemp)"
GOUT="$(mktemp)"
RSA_KEY="$(openssl genrsa 2048 2>/dev/null)"
trap 'rm -f "$AAB" "$LOG" "$GOUT"; [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null || true' EXIT
head -c 4096 /dev/zero > "$AAB"

MOCK_PID=""
python3 - "$PORT" "$LOG" <<'PY' &
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

port = int(sys.argv[1])
calls = sys.argv[2]

app = {
    "package": "com.autobrainservice.app",
    "tracks": {"production": [], "beta": [], "alpha": []},
    "edits": {},            # edit id -> last PUT release body (present = open)
    "n": 0,
    "last_status": {},      # edit id -> "completed" | "draft"
    "block_completed_once": True,  # draft-fallback scenario
    "rollout_block": False,        # True => 403 "does not allow any existing users to upgrade"
}
with open(calls, "w") as f:
    f.write("start\n")

def rec(msg):
    with open(calls, "a") as f:
        f.write(msg + "\n")

def next_eid():
    app["n"] += 1
    return "edit-%d" % app["n"]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))

    def do_DELETE(self):
        p = urlparse(self.path)
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)$", p.path)
        if m:
            eid = m.group(1)
            app["edits"].pop(eid, None)
            rec("delete %s" % eid)
            return self._json(200, {})
        self._json(404, {"error": {"code": 404}})

    def do_GET(self):
        p = urlparse(self.path)
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/tracks/([^/]+)/releases$", p.path)
        if m:
            track = m.group(1)
            exists = track in app["tracks"]
            rec("probe %s -> %s" % (track, "200" if exists else "404"))
            if exists:
                return self._json(200, {"releases": app["tracks"][track]})
            return self._json(404, {"error": {"code": 404, "message": "Track not found"}})
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/tracks/([^/]+)$", p.path)
        if m:
            eid, track = m.group(1), m.group(2)
            if eid not in app["edits"]:
                return self._json(400, {"error": {"code": 400, "message": "This Edit has been deleted.", "status": "FAILED_PRECONDITION"}})
            rel = app["tracks"].get(track, [])
            rec("tracks.get verify %s/%s -> %d releases" % (eid, track, len(rel)))
            return self._json(200, {"track": track, "releases": rel})
        self._json(404, {"error": {"code": 404}})

    def do_POST(self):
        p = urlparse(self.path)
        if p.path == "/token":
            return self._json(200, {"access_token": "fake-token"})
        if p.path == "/__mock__/ok":
            app["block_completed_once"] = False
            rec("mock mode ok")
            return self._json(200, {"mode": "ok"})
        if p.path == "/__mock__/draft-once":
            app["block_completed_once"] = True
            app["rollout_block"] = False
            rec("mock mode draft-once")
            return self._json(200, {"mode": "draft-once"})
        if p.path == "/__mock__/rollout-once":
            app["block_completed_once"] = True
            app["rollout_block"] = True
            rec("mock mode rollout-once")
            return self._json(200, {"mode": "rollout-once"})
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/edits$", p.path)
        if m:
            # AUT-952 semantics: a second insert while one edit is open
            # silently deletes the previous one.
            if app["edits"]:
                app["edits"].clear()
                rec("insert killed previous open edit")
            eid = next_eid()
            app["edits"][eid] = None
            rec("insert %s (open=%d)" % (eid, len(app["edits"])))
            return self._json(200, {"id": eid, "expiryTimeSeconds": "9999999999"})
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/tracks$", p.path)
        if m:
            eid, track = m.group(1), self._body().get("track")
            if track in app["tracks"]:
                return self._json(409, {"error": {"code": 409, "message": "Track already exists"}})
            app["tracks"][track] = []
            rec("track-create %s in %s" % (track, eid))
            return self._json(200, {"track": track, "type": "CLOSED_TESTING"})
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+):commit$", p.path)
        if m:
            eid = m.group(1)
            if eid not in app["edits"]:
                return self._json(400, {"error": {"code": 400, "message": "This Edit has been deleted.", "status": "FAILED_PRECONDITION"}})
            if app["last_status"].get(eid) == "completed" and app["block_completed_once"]:
                app["block_completed_once"] = False
                if app.get("rollout_block"):
                    rec("commit %s -> 403 does not allow any existing users to upgrade" % eid)
                    return self._json(403, {"error": {"code": 403, "message": "You cannot rollout this release because it does not allow any existing users to upgrade to the newly added APKs", "status": "PERMISSION_DENIED"}})
                rec("commit %s -> 403 targeting no countries" % eid)
                return self._json(403, {"error": {"code": 403, "message": "Release in track targeting no countries", "status": "PERMISSION_DENIED"}})
            del app["edits"][eid]
            rec("commit %s -> 200" % eid)
            return self._json(200, {})
        m = re.match(r"^/upload/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/bundles", p.path)
        if m:
            eid = m.group(1)
            if eid not in app["edits"]:
                rec("bundle upload %s -> 400 deleted" % eid)
                return self._json(400, {"error": {"code": 400, "message": "This Edit has been deleted.", "status": "FAILED_PRECONDITION"}})
            rec("bundle upload %s -> 200" % eid)
            return self._json(200, {"versionCode": 999, "sha256": "x"})
        self._json(404, {"error": {"code": 404}})

    def do_PUT(self):
        p = urlparse(self.path)
        m = re.match(r"^/androidpublisher/v3/applications/[^/]+/edits/([^/]+)/tracks/([^/]+)$", p.path)
        if m:
            eid, track = m.group(1), m.group(2)
            if eid not in app["edits"]:
                return self._json(400, {"error": {"code": 400, "message": "This Edit has been deleted.", "status": "FAILED_PRECONDITION"}})
            body = self._body()
            rel = body.get("releases")
            if not isinstance(rel, list) or not rel:
                rec("track-put %s %s -> 400 bad schema (releases must be a non-empty array)" % (eid, track))
                return self._json(400, {"error": {"code": 400, "message": "releases must be a non-empty array", "status": "INVALID_ARGUMENT"}})
            status = rel[0].get("status", "completed")
            app["last_status"][eid] = status
            rec("track-put-body %s %s %s" % (eid, track, json.dumps(rel)))
            vc = rel[0].get("versionCodes", [])
            app["tracks"].setdefault(track, []).append({"versionCodes": vc, "status": status})
            rec("track-put %s %s status=%s" % (eid, track, status))
            return self._json(200, {"track": track, "releases": rel})
        self._json(404, {"error": {"code": 404}})

srv = HTTPServer(("127.0.0.1", port), H)
srv.serve_forever()
PY
MOCK_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break; sleep 0.25; done

export PLAY_API_BASE="http://127.0.0.1:$PORT"
export GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(jq -n --arg email mock@example.com --arg uri "http://127.0.0.1:$PORT/token" --arg key "$RSA_KEY" '{client_email:$email,token_uri:$uri,private_key:$key}')"
export PLAY_PACKAGE_NAME="com.autobrainservice.app"
export PLAY_RELEASE_NOTES="mock release"
export PLAY_LOG_FILE="$LOG"
export GITHUB_OUTPUT="$GOUT"

fail() { echo "FAIL: $1" >&2; exit 1; }
mock_mode() { curl -sS -X POST "http://127.0.0.1:$PORT/__mock__/$1" >/dev/null; }

echo "== scenario 1: track missing -> create in own edit, then single-edit upload =="
mock_mode ok
: > "$LOG"
# default target is 'alpha' (a track the mock already has); pass an explicit
# non-existent track to exercise the missing-track create path.
out1="$(bash "$SCRIPT" "$AAB" missinglane 2>&1)" || fail "scenario 1 failed: $out1"
grep -q "track 'missinglane' not found" <<<"$out1" || fail "missing-track path not taken"
grep -q "closed testing track 'missinglane' created" <<<"$out1" || fail "track not created"
grep -q "uploaded $AAB -> versionCode 999" <<<"$out1" || fail "upload not recorded"
grep -q "closed testing (missinglane) release OK" <<<"$out1" || fail "final success line missing"
grep -q "insert killed previous open edit" "$LOG" && fail "two edits were open simultaneously (AUT-952 regression)"
echo "OK"

echo "== scenario 2: default alpha track exists -> single-edit upload only =="
mock_mode ok
: > "$LOG"
out2="$(bash "$SCRIPT" "$AAB" 2>&1)" || fail "scenario 2 failed: $out2"
grep -q "uploaded $AAB -> versionCode 999" <<<"$out2" || fail "upload not recorded"
grep -q "closed testing (alpha) release OK" <<<"$out2" || fail "final success line missing"
n_insert="$(grep -c "^insert edit-" "$LOG")"
[[ "$n_insert" == "2" ]] || fail "expected 2 edit inserts (main + verify), got $n_insert"
grep -q "insert killed previous open edit" "$LOG" && { echo "--- mock log ---" >&2; cat "$LOG" >&2; fail "probe-edit regression"; }
echo "OK"

echo "== scenario 3: completed commit blocked (no tester audience) -> draft fallback =="
mock_mode draft-once
: > "$LOG"
out3="$(bash "$SCRIPT" "$AAB" 2>&1)" || fail "scenario 3 failed: $out3"
grep -q "targeting no countries" <<<"$out3" || fail "draft-fallback warning missing"
grep -q "ASK-NATHAN" <<<"$out3" || fail "tester-audience ask missing"
grep -q "needs_tester_audience=true" "$GOUT" || fail "GITHUB_OUTPUT needs_tester_audience not set"
grep -q "status draft" <<<"$out3" || fail "final status not draft"
echo "OK"

echo "== scenario 4: rollout-track 403 -> inProgress userFraction fallback (AUT-4987) =="
mock_mode rollout-once
: > "$LOG"
out4="$(bash "$SCRIPT" "$AAB" 2>&1)" || fail "scenario 4 failed: $out4"
grep -q "does not allow any existing users to upgrade" <<<"$out4" || fail "rollout-403 warning missing"
grep -q "status=inProgress userFraction=0.999" <<<"$out4" || fail "inProgress retry not attempted (dead fallback regression)"
grep -qE "track-put(-body)? [a-z0-9-]+ alpha (status=inProgress|.*\"status\":\"inProgress\")" "$LOG" || fail "mock never received an inProgress track PUT"
grep -q "userFraction.: *0.999" "$LOG" || fail "userFraction=0.999 not sent to the track PUT"
grep -q "closed testing (alpha) release OK" <<<"$out4" || fail "final success line missing"
echo "OK"

echo "ALL SCENARIOS PASSED"
