#!/usr/bin/env bash
#
# Nostromo core, end-to-end smoke test (plan task T7).
#
# This is the project's primary feedback loop: it asserts the observable contract of the
# generic core (health, invite, auth, documents, per-document versioning, group access,
# file transfer, user enrich) against a LOCAL running instance.
#
# What it needs:
#   - a running PocketBase instance (see download.sh / serve.sh), reachable at $BASE_URL;
#   - a bootstrapped superuser (see bootstrap.sh).
#
# How to run:
#   bash infra/pocketbase/scripts/download.sh
#   bash infra/pocketbase/scripts/serve.sh &        # or in another terminal
#   bash infra/pocketbase/scripts/bootstrap.sh
#   bash infra/pocketbase/scripts/smoke.sh
#
# Configuration (environment variables, sane dev defaults):
#   BASE_URL           default http://127.0.0.1:8090
#   SUPERUSER_EMAIL    default dev@nostromo.local
#   SUPERUSER_PASSWORD default DevOnly1!
#
# ASSUMPTION (dev credentials): the defaults above are the SAME development credentials that
# bootstrap.sh uses (dev@nostromo.local / DevOnly1!, see that script). The password is at
# least 8 characters because PocketBase rejects shorter superuser passwords. Both scripts
# keep them in sync; change them together or override SUPERUSER_PASSWORD explicitly.
# These credentials are DEV ONLY and must never reach production.
#
# The script is re-runnable against a non-empty instance: user emails, the group name and
# the document id carry a per-run random suffix. The document id is 15 lowercase
# alphanumeric characters, matching ^[a-z0-9]{15}$ as required by the client-id contract.
#
# Requires: bash, curl, python3.
#
# Exit status: 0 when every check passes, 1 as soon as any check fails.

set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8090}"
SUPERUSER_EMAIL="${SUPERUSER_EMAIL:-dev@nostromo.local}"
SUPERUSER_PASSWORD="${SUPERUSER_PASSWORD:-DevOnly1!}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHECKS=0
FAILURES=0

# --- helpers ---------------------------------------------------------------------------

# api_json METHOD PATH TOKEN OUT_FILE [JSON_BODY]
# Runs curl, stores the response body in OUT_FILE and prints the HTTP status on stdout.
# Never uses curl -f: expected non-2xx statuses are part of the contract and are asserted
# explicitly by the caller. TOKEN is the raw PocketBase token ("" for anonymous).
api_json() {
  local method="$1" path="$2" token="$3" out="$4" body="${5:-}"
  local args=(-sS -X "$method" -o "$out" -w '%{http_code}')
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: $token")
  fi
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  curl "${args[@]}" "$BASE_URL$path" || true
}

# json_get FILE PATH: prints a value from a JSON file using a dotted path, e.g. "users[0].name".
# Missing keys, wrong types and unparseable bodies print an empty string instead of failing.
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    cur = json.load(open(sys.argv[1]))
    for part in sys.argv[2].split('.'):
        name, idx = part, None
        if '[' in part:
            name, rest = part.split('[', 1)
            idx = int(rest.rstrip(']'))
        if name:
            cur = cur[name]
        if idx is not None:
            cur = cur[idx]
except Exception:
    print("")
    sys.exit(0)
if cur is None:
    print("")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
PY
}

# json_body '{...}' KEY VALUE ...: prints a JSON object, safely escaping the values.
json_body() {
  python3 -c '
import json, sys
pairs = sys.argv[1:]
print(json.dumps({pairs[i]: pairs[i + 1] for i in range(0, len(pairs), 2)}))
' "$@"
}

body_snippet() {
  head -c 300 "$1" 2>/dev/null | tr '\n' ' '
}

# check NUM DESCRIPTION OK DETAIL
# OK is "0" for a pass, anything else for a fail. Always prints a numbered PASS/FAIL line.
check() {
  local num="$1" desc="$2" ok="$3" detail="${4:-}"
  CHECKS=$((CHECKS + 1))
  if [[ "$ok" == "0" ]]; then
    printf '%2d. PASS %s\n' "$num" "$desc"
  else
    FAILURES=$((FAILURES + 1))
    if [[ -n "$detail" ]]; then
      printf '%2d. FAIL %s\n         %s\n' "$num" "$desc" "$detail"
    else
      printf '%2d. FAIL %s\n' "$num" "$desc"
    fi
  fi
}

# --- per-run random identifiers --------------------------------------------------------

# 15 lowercase alphanumeric characters: "smoke" + 10 random chars.
doc_id="smoke$(python3 -c 'import secrets,string;a=string.ascii_lowercase+string.digits;print("".join(secrets.choice(a) for _ in range(10)))')"
suffix="${doc_id#smoke}"
alice_email="alice+${suffix}@nostromo.test"
alice_name="Smoke Alice ${suffix}"
bob_email="bob+${suffix}@nostromo.test"
bob_name="Smoke Bob ${suffix}"
carol_email="carol+${suffix}@nostromo.test"
carol_name="Smoke Carol ${suffix}"
group_name="smoke-group-${suffix}"
unrelated_id="$(python3 -c 'import secrets,string;a=string.ascii_lowercase+string.digits;print("".join(secrets.choice(a) for _ in range(15)))')"

echo "Nostromo smoke test against $BASE_URL"
echo "run suffix: $suffix (document id: $doc_id)"
echo

# --- 1. health -------------------------------------------------------------------------

status="$(api_json GET /api/health "" "$TMP/health.json")"
ok=1
[[ "$status" == "200" ]] && ok=0
check 1 "health endpoint at /api/health returns 200" "$ok" "status=$status body=$(body_snippet "$TMP/health.json")"

if [[ "$status" != "200" ]]; then
  printf '\nAborting: %s is not reachable.\n' "$BASE_URL" >&2
  printf 'Start the instance first: bash infra/pocketbase/scripts/download.sh && bash infra/pocketbase/scripts/serve.sh\n' >&2
  exit 1
fi

# --- 2. superuser auth -----------------------------------------------------------------

status="$(api_json POST /api/collections/_superusers/auth-with-password "" "$TMP/super.json" \
  "$(json_body identity "$SUPERUSER_EMAIL" password "$SUPERUSER_PASSWORD")")"
SUPER_TOKEN="$(json_get "$TMP/super.json" token)"
ok=1
[[ "$status" == "200" && -n "$SUPER_TOKEN" ]] && ok=0
check 2 "superuser authenticates ($SUPERUSER_EMAIL)" "$ok" "status=$status body=$(body_snippet "$TMP/super.json")"

# --- 3. invite alice -------------------------------------------------------------------

status="$(api_json POST /nostromo/invite "$SUPER_TOKEN" "$TMP/invite_alice.json" \
  "$(json_body email "$alice_email" name "$alice_name")")"
alice_id="$(json_get "$TMP/invite_alice.json" userId)"
alice_password="$(json_get "$TMP/invite_alice.json" password)"
alice_created="$(json_get "$TMP/invite_alice.json" created)"
ok=1
[[ "$status" == "200" && "$alice_created" == "true" && -n "$alice_password" && -n "$alice_id" ]] && ok=0
check 3 "invite alice returns userId, created:true and a password" "$ok" "status=$status body=$(body_snippet "$TMP/invite_alice.json")"

# --- 4. invite alice again (idempotent) ------------------------------------------------

status2="$(api_json POST /nostromo/invite "$SUPER_TOKEN" "$TMP/invite_alice2.json" \
  "$(json_body email "$alice_email" name "$alice_name")")"
alice_id2="$(json_get "$TMP/invite_alice2.json" userId)"
alice_created2="$(json_get "$TMP/invite_alice2.json" created)"
alice_password2="$(json_get "$TMP/invite_alice2.json" password)"
ok=1
[[ "$status2" == "200" && "$alice_created2" == "false" && "$alice_id2" == "$alice_id" && -z "$alice_password2" ]] && ok=0
check 4 "second invite of alice: same userId, created:false, no password" "$ok" "status=$status2 body=$(body_snippet "$TMP/invite_alice2.json")"

# --- 5. alice auth ---------------------------------------------------------------------

status="$(api_json POST /api/collections/users/auth-with-password "" "$TMP/alice_auth.json" \
  "$(json_body identity "$alice_email" password "$alice_password")")"
alice_token="$(json_get "$TMP/alice_auth.json" token)"
ok=1
[[ "$status" == "200" && -n "$alice_token" ]] && ok=0
check 5 "alice authenticates with the invited password" "$ok" "status=$status body=$(body_snippet "$TMP/alice_auth.json")"

# --- 6. alice creates a document with a client id --------------------------------------

status="$(api_json POST /api/collections/documents/records "$alice_token" "$TMP/doc_create.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"owner":sys.argv[2],"payload":{"kind":"smoke","suffix":sys.argv[3]}}))' \
    "$doc_id" "$alice_id" "$suffix")")"
doc_id_echo="$(json_get "$TMP/doc_create.json" id)"
doc_owner="$(json_get "$TMP/doc_create.json" owner)"
doc_version="$(json_get "$TMP/doc_create.json" version)"
ok=1
[[ "$status" == "200" && "$doc_id_echo" == "$doc_id" && "$doc_owner" == "$alice_id" && "$doc_version" == "1" ]] && ok=0
check 6 "alice creates document $doc_id (owner set, version 1)" "$ok" "status=$status body=$(body_snippet "$TMP/doc_create.json")"

# --- 7. duplicate create with the same id fails ----------------------------------------

status="$(api_json POST /api/collections/documents/records "$alice_token" "$TMP/doc_dup.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"owner":sys.argv[2],"payload":{}}))' "$doc_id" "$alice_id")")"
ok=1
[[ "$status" == "400" ]] && ok=0
check 7 "duplicate create with the same id is rejected with 400" "$ok" "status=$status body=$(body_snippet "$TMP/doc_dup.json")"

# --- 8. invite and authenticate bob ----------------------------------------------------

invite_status="$(api_json POST /nostromo/invite "$SUPER_TOKEN" "$TMP/invite_bob.json" \
  "$(json_body email "$bob_email" name "$bob_name")")"
bob_id="$(json_get "$TMP/invite_bob.json" userId)"
bob_password="$(json_get "$TMP/invite_bob.json" password)"
bob_created="$(json_get "$TMP/invite_bob.json" created)"
auth_status="$(api_json POST /api/collections/users/auth-with-password "" "$TMP/bob_auth.json" \
  "$(json_body identity "$bob_email" password "$bob_password")")"
bob_token="$(json_get "$TMP/bob_auth.json" token)"
ok=1
[[ "$invite_status" == "200" && "$bob_created" == "true" && -n "$bob_password" && -n "$bob_id" && \
   "$auth_status" == "200" && -n "$bob_token" ]] && ok=0
check 8 "invite and authenticate bob" "$ok" "invite=$invite_status auth=$auth_status body=$(body_snippet "$TMP/bob_auth.json")"

# --- 9. bob cannot view alice's document -----------------------------------------------

status="$(api_json GET "/api/collections/documents/records/$doc_id" "$bob_token" "$TMP/bob_view.json")"
ok=1
[[ "$status" == "404" ]] && ok=0
check 9 "bob's view of alice's document returns 404" "$ok" "status=$status body=$(body_snippet "$TMP/bob_view.json")"

# --- 10. bob's list does not contain it ------------------------------------------------

status="$(curl -sS -G -o "$TMP/bob_list.json" -w '%{http_code}' \
  -H "Authorization: $bob_token" \
  --data-urlencode "filter=id='$doc_id'" \
  --data-urlencode 'perPage=1' \
  "$BASE_URL/api/collections/documents/records" || true)"
bob_list_total="$(json_get "$TMP/bob_list.json" totalItems)"
ok=1
[[ "$status" == "200" && "$bob_list_total" == "0" ]] && ok=0
check 10 "bob's list filtered on the document id is empty" "$ok" "status=$status totalItems=$bob_list_total body=$(body_snippet "$TMP/bob_list.json")"

# --- 11. superuser grants bob read access through a group ------------------------------

group_status="$(api_json POST /api/collections/groups/records "$SUPER_TOKEN" "$TMP/group.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"members":[sys.argv[2]]}))' "$group_name" "$bob_id")")"
group_id="$(json_get "$TMP/group.json" id)"
access_status="$(api_json POST /api/collections/document_access/records "$SUPER_TOKEN" "$TMP/access.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"document":sys.argv[1],"group":sys.argv[2],"right":"read"}))' "$doc_id" "$group_id")")"
access_id="$(json_get "$TMP/access.json" id)"
ok=1
[[ "$group_status" == "200" && -n "$group_id" && "$access_status" == "200" && -n "$access_id" ]] && ok=0
check 11 "superuser creates a group with bob and a read access row" "$ok" "group=$group_status access=$access_status body=$(body_snippet "$TMP/access.json")"

# --- 12. bob can now view the document -------------------------------------------------

status="$(api_json GET "/api/collections/documents/records/$doc_id" "$bob_token" "$TMP/bob_view2.json")"
view_version="$(json_get "$TMP/bob_view2.json" version)"
ok=1
[[ "$status" == "200" && "$view_version" == "1" ]] && ok=0
check 12 "bob's view now returns 200 with version 1" "$ok" "status=$status version=$view_version body=$(body_snippet "$TMP/bob_view2.json")"

# --- 13. bob cannot update (read-only) -------------------------------------------------

status="$(api_json PATCH "/api/collections/documents/records/$doc_id" "$bob_token" "$TMP/bob_update.json" \
  '{"expectedVersion":1,"payload":{"by":"bob"}}')"
ok=1
[[ "$status" == "404" ]] && ok=0
check 13 "bob's update with expectedVersion 1 returns 404 (read-only)" "$ok" "status=$status body=$(body_snippet "$TMP/bob_update.json")"

# --- 14. alice updates the document ----------------------------------------------------

status="$(api_json PATCH "/api/collections/documents/records/$doc_id" "$alice_token" "$TMP/alice_update.json" \
  '{"expectedVersion":1,"payload":{"rev":2}}')"
update_version="$(json_get "$TMP/alice_update.json" version)"
ok=1
[[ "$status" == "200" && "$update_version" == "2" ]] && ok=0
check 14 "alice's update with expectedVersion 1 returns 200 with version 2" "$ok" "status=$status version=$update_version body=$(body_snippet "$TMP/alice_update.json")"

# --- 15. stale write is rejected -------------------------------------------------------

status="$(api_json PATCH "/api/collections/documents/records/$doc_id" "$alice_token" "$TMP/alice_stale.json" \
  '{"expectedVersion":1,"payload":{"rev":"stale"}}')"
ok=1
[[ "$status" == "409" ]] && ok=0
check 15 "alice's update with stale expectedVersion 1 returns 409" "$ok" "status=$status body=$(body_snippet "$TMP/alice_stale.json")"

# --- 16. superuser flips the access row to write, bob updates --------------------------

flip_status="$(api_json PATCH "/api/collections/document_access/records/$access_id" "$SUPER_TOKEN" "$TMP/access_write.json" \
  '{"right":"write"}')"
bob_update_status="$(api_json PATCH "/api/collections/documents/records/$doc_id" "$bob_token" "$TMP/bob_update2.json" \
  '{"expectedVersion":2,"payload":{"rev":3}}')"
bob_update_version="$(json_get "$TMP/bob_update2.json" version)"
ok=1
[[ "$flip_status" == "200" && "$bob_update_status" == "200" && "$bob_update_version" == "3" ]] && ok=0
check 16 "after grant is flipped to write, bob's update returns 200 with version 3" "$ok" "flip=$flip_status status=$bob_update_status version=$bob_update_version body=$(body_snippet "$TMP/bob_update2.json")"

# --- 17. alice uploads a file (multipart PATCH) ----------------------------------------

printf 'nostromo smoke file %s\n' "$suffix" > "$TMP/upload.bin"
# Multipart form fields arrive as strings, so the version hook must coerce expectedVersion
# (e.g. toInt(...)) rather than compare it to the numeric field with strict equality.
upload_status="$(curl -sS -X PATCH -o "$TMP/upload.json" -w '%{http_code}' \
  -H "Authorization: $alice_token" \
  -F 'expectedVersion=3' \
  -F "file=@$TMP/upload.bin" \
  "$BASE_URL/api/collections/documents/records/$doc_id" || true)"
file_name="$(json_get "$TMP/upload.json" file)"
ok=1
[[ "$upload_status" == "200" && -n "$file_name" ]] && ok=0
check 17 "alice uploads a file to the document via multipart PATCH" "$ok" "status=$upload_status file=$file_name body=$(body_snippet "$TMP/upload.json")"

# --- 18. alice downloads the file via a file token and the bytes match -----------------
#
# The `file` field is protected (migration 005): a download needs a short-lived file token
# from POST /api/files/token, sent with the caller's Authorization header and passed as
# `?token=` on the file URL. A plain Authorization header on the file URL is NOT sufficient;
# the anonymous case is the regression guard in check 21.
if [[ -n "$file_name" ]]; then
  file_token_status="$(curl -sS -X POST -o "$TMP/file_token.json" -w '%{http_code}' \
    -H "Authorization: $alice_token" \
    "$BASE_URL/api/files/token" || true)"
  file_token="$(json_get "$TMP/file_token.json" token)"
  if [[ -n "$file_token" ]]; then
    download_status="$(curl -sS -o "$TMP/downloaded.bin" -w '%{http_code}' \
      "$BASE_URL/api/files/documents/$doc_id/$file_name?token=$file_token" || true)"
  else
    download_status="no-token"
  fi
else
  file_token_status="skipped"
  download_status="skipped"
fi
if [[ "$file_token_status" == "200" && "$download_status" == "200" && -f "$TMP/downloaded.bin" ]] && cmp -s "$TMP/upload.bin" "$TMP/downloaded.bin"; then
  ok=0
else
  ok=1
fi
check 18 "alice downloads the file via a file token, bytes match" "$ok" "token=$file_token_status download=$download_status"

# --- 19. bob (group-granted reader) downloads via his own file token -------------------
#
# Protected file access is VIEW-RULE based, not owner based: bob holds a write grant through a
# group (checks 11 and 16), so his OWN file token must fetch alice's file, byte for byte. A valid
# token from a caller without access is the rejected case in check 20.
if [[ -n "$file_name" ]]; then
  bob_token_status="$(curl -sS -X POST -o "$TMP/bob_file_token.json" -w '%{http_code}' \
    -H "Authorization: $bob_token" \
    "$BASE_URL/api/files/token" || true)"
  bob_file_token="$(json_get "$TMP/bob_file_token.json" token)"
  if [[ -n "$bob_file_token" ]]; then
    bob_download_status="$(curl -sS -o "$TMP/bob_downloaded.bin" -w '%{http_code}' \
      "$BASE_URL/api/files/documents/$doc_id/$file_name?token=$bob_file_token" || true)"
  else
    bob_download_status="no-token"
  fi
else
  bob_token_status="skipped"
  bob_download_status="skipped"
fi
if [[ "$bob_token_status" == "200" && "$bob_download_status" == "200" && -f "$TMP/bob_downloaded.bin" ]] && cmp -s "$TMP/upload.bin" "$TMP/bob_downloaded.bin"; then
  ok=0
else
  ok=1
fi
check 19 "bob (group-granted) downloads via his own file token, bytes match" "$ok" "token=$bob_token_status download=$bob_download_status"

# --- 20. carol's valid file token does not grant access --------------------------------
#
# The other security-defining direction: a valid token proves WHO is asking, the viewRule decides
# WHETHER they may read. Carol is invited and authenticated but shares no group and no access row
# with alice's document, so her own freshly minted file token must NOT fetch the bytes.
invite_carol_status="$(api_json POST /nostromo/invite "$SUPER_TOKEN" "$TMP/invite_carol.json" \
  "$(json_body email "$carol_email" name "$carol_name")")"
carol_id="$(json_get "$TMP/invite_carol.json" userId)"
carol_password="$(json_get "$TMP/invite_carol.json" password)"
carol_auth_status="$(api_json POST /api/collections/users/auth-with-password "" "$TMP/carol_auth.json" \
  "$(json_body identity "$carol_email" password "$carol_password")")"
carol_token="$(json_get "$TMP/carol_auth.json" token)"
carol_token_status="skipped"
carol_download_status="skipped"
if [[ -n "$file_name" && -n "$carol_token" ]]; then
  carol_token_status="$(curl -sS -X POST -o "$TMP/carol_file_token.json" -w '%{http_code}' \
    -H "Authorization: $carol_token" \
    "$BASE_URL/api/files/token" || true)"
  carol_file_token="$(json_get "$TMP/carol_file_token.json" token)"
  if [[ -n "$carol_file_token" ]]; then
    carol_download_status="$(curl -sS -o "$TMP/carol_downloaded.bin" -w '%{http_code}' \
      "$BASE_URL/api/files/documents/$doc_id/$file_name?token=$carol_file_token" || true)"
  fi
fi
ok=1
[[ "$invite_carol_status" == "200" && -n "$carol_id" && -n "$carol_password" && \
   "$carol_auth_status" == "200" && -n "$carol_token" && \
   "$carol_token_status" == "200" && "$carol_download_status" == "404" ]] && ok=0
check 20 "carol's valid file token on alice's file returns 404 (no access)" "$ok" "invite=$invite_carol_status auth=$carol_auth_status token=$carol_token_status download=$carol_download_status"

# --- 21. anonymous file download is denied (protected-field regression guard) ----------
#
# Before migration 005 the file URL was a capability: an anonymous GET returned 200 with the
# bytes. With the `file` field protected an anonymous GET with no token must return 404. This runs
# while the document and file still exist (deletion is checks 26-27); a missing file would 404 for
# the wrong reason and make the guard meaningless.
if [[ -n "$file_name" ]]; then
  anon_file_status="$(curl -sS -o "$TMP/anon_file.bin" -w '%{http_code}' \
    "$BASE_URL/api/files/documents/$doc_id/$file_name" || true)"
else
  anon_file_status="skipped"
fi
ok=1
[[ "$anon_file_status" == "404" ]] && ok=0
check 21 "anonymous file download returns 404 (protected)" "$ok" "status=$anon_file_status"

# --- 22. bob enriches alice ------------------------------------------------------------

status="$(api_json POST /nostromo/users/enrich "$bob_token" "$TMP/enrich_alice.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"ids":[sys.argv[1]]}))' "$alice_id")")"
enriched_id="$(json_get "$TMP/enrich_alice.json" 'users[0].id')"
enriched_name="$(json_get "$TMP/enrich_alice.json" 'users[0].name')"
ok=1
[[ "$status" == "200" && "$enriched_id" == "$alice_id" && "$enriched_name" == "$alice_name" ]] && ok=0
check 22 "bob enrich [alice] returns alice's id and name" "$ok" "status=$status body=$(body_snippet "$TMP/enrich_alice.json")"

# --- 23. bob enriches an unrelated id --------------------------------------------------

status="$(api_json POST /nostromo/users/enrich "$bob_token" "$TMP/enrich_none.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"ids":[sys.argv[1]]}))' "$unrelated_id")")"
enriched_count="$(json_get "$TMP/enrich_none.json" users | tr -d '[:space:]')"
ok=1
[[ "$status" == "200" && "$enriched_count" == "[]" ]] && ok=0
check 23 "bob enrich of an unrelated id returns an empty list" "$ok" "status=$status users=$enriched_count body=$(body_snippet "$TMP/enrich_none.json")"

# --- 24. unauthenticated create is rejected --------------------------------------------

# PocketBase 0.40.4 answers this with 400 and the message "Failed to create record."
# (verified live): a create whose createRule fails is a validation error, not a 401/403.
# Both the status and the message are asserted so the check cannot stay green while
# authentication is broken.
status="$(api_json POST /api/collections/documents/records "" "$TMP/anon_create.json" \
  "$(python3 -c 'import json,sys;print(json.dumps({"id":sys.argv[1],"owner":sys.argv[2],"payload":{}}))' "$unrelated_id" "$alice_id")")"
anon_message="$(json_get "$TMP/anon_create.json" message)"
ok=1
[[ "$status" == "400" && "$anon_message" == "Failed to create record." ]] && ok=0
check 24 "unauthenticated document create is rejected with 400" "$ok" "status=$status message=$anon_message body=$(body_snippet "$TMP/anon_create.json")"

# --- 25. read-only group member cannot delete the document -----------------------------
#
# Check 16 flipped bob's access row to write. Flip it back to read so bob is a read-level
# group member here: a delete needs the write right, so the rule must deny it. The denial
# status is asserted from a live run, not guessed.
flip_read_status="$(api_json PATCH "/api/collections/document_access/records/$access_id" "$SUPER_TOKEN" "$TMP/access_read.json" \
  '{"right":"read"}')"
status="$(api_json DELETE "/api/collections/documents/records/$doc_id" "$bob_token" "$TMP/bob_delete.json")"
ok=1
[[ "$flip_read_status" == "200" && "$status" == "404" ]] && ok=0
check 25 "bob (read-only) cannot delete the document, rule denies with 404" "$ok" "flip=$flip_read_status status=$status body=$(body_snippet "$TMP/bob_delete.json")"

# --- 26. owner deletes a document that has an access row -------------------------------
#
# Regression guard for the cascade-delete defect: before the fix this returned 400
# ("... not part of a required relation reference.") even for the owner.
status="$(api_json DELETE "/api/collections/documents/records/$doc_id" "$alice_token" "$TMP/alice_delete.json")"
ok=1
[[ "$status" == "204" ]] && ok=0
check 26 "alice deletes her document that still has an access row (204)" "$ok" "status=$status body=$(body_snippet "$TMP/alice_delete.json")"

# --- 27. document gone for owner and group member; access row cascaded -----------------
alice_delete_view="$(api_json GET "/api/collections/documents/records/$doc_id" "$alice_token" "$TMP/alice_view_gone.json")"
bob_gone_view="$(api_json GET "/api/collections/documents/records/$doc_id" "$bob_token" "$TMP/bob_view_gone.json")"
access_list_status="$(curl -sS -G -o "$TMP/access_list.json" -w '%{http_code}' \
  -H "Authorization: $SUPER_TOKEN" \
  --data-urlencode "filter=id='$access_id'" \
  --data-urlencode 'perPage=1' \
  "$BASE_URL/api/collections/document_access/records" || true)"
access_list_total="$(json_get "$TMP/access_list.json" totalItems)"
ok=1
[[ "$alice_delete_view" == "404" && "$bob_gone_view" == "404" && "$access_list_status" == "200" && "$access_list_total" == "0" ]] && ok=0
check 27 "document gone for owner and group member, access row cascaded (404/404, 0 rows)" "$ok" "alice=$alice_delete_view bob=$bob_gone_view access=$access_list_status totalItems=$access_list_total"

# --- summary ---------------------------------------------------------------------------

printf '\n%d checks, %d passed, %d failed\n' "$CHECKS" "$((CHECKS - FAILURES))" "$FAILURES"

if ((FAILURES > 0)); then
  exit 1
fi
