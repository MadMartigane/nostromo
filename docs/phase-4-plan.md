# Phase 4 Plan: Build the Nostromo Core

> Status: execution-ready plan. Inputs: `docs/decisions.md` (validated), `docs/app-integration-handoff.md`,
> `docs/pocketbase-poc-analysis.md`, reference implementation in `ballerStats` branch `pocketbase`
> (`infra/pocketbase/`). Section numbers below refer to `decisions.md`.

## 1. Goal and scope

Build the generic core on PocketBase: users with signup disabled, opaque documents with client ids and
an optional file, groups plus an access relation table, API rules enforcing creator-private and
group-granted access, stale-write rejection, two custom routes, local dev scripts, a deployment note,
and a scripted end-to-end smoke test as the primary feedback loop.

Out of scope (restated from section 2 and phase 4 framing): any app data model, document granularity
or sync engine; rights-management UI or endpoints (dashboard only, section 5); SMTP, password
recovery, admin right level, multi-club; realtime transport changes; production nginx/TLS
configuration (section 9).

## 2. Verified facts (checked against PocketBase v0.40.4 source)

- Latest stable release is **0.40.4** (checked 2026-09-14). Pin it in `download.sh`.
- **Client-provided ids are accepted.** The system `id` field is a text field with `min: 15`,
  `max: 15`, pattern `^[a-z0-9]+$`, and `autogeneratePattern: [a-z0-9]{15}`. The autogenerator only
  fills the value when it is empty (`core/field_text.go`, `hasZeroValue && IsNew`). A client-sent id
  matching `^[a-z0-9]{15}$` is used as-is; the primary key enforces uniqueness. A create retried with
  the same id fails with 400, so no duplication is possible.
- **`updated` precision is milliseconds.** The autodate field writes `types.NowDateTime()` serialized
  as `2006-01-02 15:04:05.000Z` (`tools/types/datetime.go`). Two writes in the same millisecond
  produce identical `updated` values. There is no monotonic counter and no tie-break.
- **Collections created in JS migrations do not get `created`/`updated` automatically.**
  `initDefaultFields` only adds the `id` field; the dashboard adds the two autodate fields
  client-side. Our migrations must declare them explicitly on every collection.
- **Rule failure on update/view returns 404** (`apis/record_crud.go` maps the rule-filtered refetch
  miss to `NotFoundError`). So a stale-write hook throwing 409 is cleanly distinguishable from
  "no access" (404) and "bad payload" (400).
- **The default `users` collection has a public create rule (`""`)**. Disabling signup requires
  explicitly setting `createRule = null` in a migration.
- Access-rule evaluation runs with hidden-field access enabled, so a rule on `documents` may traverse
  `document_access` even though `document_access` itself is superuser-locked (all rules null).
- File downloads (`/api/files/...`) are gated by the record's `viewRule` (`apis/file.go`), so the
  document ACL also protects attached files. `$apis.requireAuth()` / `$apis.requireSuperuserAuth()`,
  `$security.randomString`, `findRecordsByFilter` are all available in `pb_hooks` (POC precedent).

## 3. Technical decisions taken by this plan

Resolving the five open items of decisions.md section 13:

1. **`updated` precision**: millisecond, fixed layout (verified). Tie-break problem is real. Resolved
   by decision 5 below: `updated` stays as audit/display timestamp only.
2. **Anti-leak rule form**: one back-relation path per conjunct, joined by `&&`, using any-of
   operators. Exact expression in section 4. Justification: within one rule expression, the same
   back-relation path (`document_access_via_document`) resolves to a single shared SQL join alias
   (`core/record_field_resolver.go` deduplicates joins by alias), and any-of operators (`?=`) compile
   to plain per-row comparisons on that alias without the multi-match subquery wrapper
   (`tools/search/filter.go`). SQL tuple semantics then evaluate `right` and `group.members` on the
   same joined access row. The leak appears only if the two conditions travel through different
   paths (different aliases, combined by separate EXISTS subqueries); the plan forbids that form.
   The chosen form is the same idiom the POC validated for `team_members`.
3. **Client ids**: confirmed, pattern `^[a-z0-9]{15}$` exactly (15 chars, lowercase alphanumeric).
4. **Enrich endpoint**: still needed, because `users` is locked to self-only and apps cannot render
   any author name without it. Shape: POST `/nostromo/users/enrich`, returns `{id, name}` only, no
   email. Authorization: the caller may resolve a target user only if (a) both are members of a
   common group, or (b) the target owns a document the caller can read. Human check H1 (is name-only
   enough for apps).
5. **Stale-write mechanism and status code**: option (b), a dedicated numeric `version` field.
   - Option (a) (compare client-expected `updated` against native `updated` inside the update rule)
     is expressible but fails the same-millisecond case: two writes within one ms share an `updated`
     value, so the second stale writer still matches and the lost update goes undetected. It also
     overloads the rule's 404 with conflict semantics.
   - Option (b): `version` starts at 1 on create, is incremented server-side on every successful
     update. The client sends `expectedVersion` (number) with each update, equal to the `version` it
     last saw. A mismatch throws **409 Conflict** from an `onRecordUpdateRequest` hook. 409 is
     reserved for staleness, 404 means "not found or not allowed", 400 means invalid payload. The
     client learns the current version from any read (`version` is a normal readable field) and from
     the 409 response re-pulling the document.
   - This refines, not reverses, section 6: versioning stays server-authoritative and per document;
     the native `updated` remains the server clock; the app still sends no clock of its own. The
     numeric token removes the precision and tie-break problem entirely (open item 1).

Supporting decisions:

- **Invite authorization**: superuser-only (`$apis.requireSuperuserAuth()`). On a shared multi-app
  instance, any-authenticated invite would let any app's user mint accounts for another app. Password
  generated server-side (16 chars, `[A-Za-z0-9]`), returned once. Idempotent on email: second call
  returns the existing `userId` with no password and `created: false`. Creates no membership rows.
- **Owner enforcement**: `documents.owner` is required and forced by the create rule
  (`@request.body.owner = @request.auth.id`), not by a hook. Rules stay the security backbone.
- **Delete right**: same rule as update (owner or write-level access). Kept consistent rather than
  inventing a third level.
- **File attachment**: one optional file, 20 MiB cap, no MIME restriction (the core is generic; apps
  own the file policy per section 11).
- **Force password change at first login** (section 8 recommendation): deferred, no native
  PocketBase mechanism exists and a blocking hook risks lockout. Human check H2.
- **External paths**: nginx on each app domain proxies `/nostromo/` (no prefix strip, custom routes
  are registered at their full path) and `/api/` (PocketBase standard endpoints) to the same
  instance. PocketBase cannot serve its API and admin UI under a rewritten subpath, so the
  strip-prefix variant is rejected. Same-origin, so no CORS in production.

## 4. Data model and rules

All in versioned JS migrations, style copied from the reference `002_collections.js` / `003_rules.js`
(explicit fields, explicit revert, no dashboard edits).

**`001_core_collections.js`** creates (with explicit `created`/`updated` autodate fields on each):

- `documents`: `owner` (relation `users`, maxSelect 1, required), `payload` (json, optional),
  `file` (file, maxSelect 1, maxSize 20971520), `version` (number, required).
- `groups`: `name` (text, required, max 200), `members` (relation `users`, maxSelect 200).
  Unique index on `name`.
- `document_access`: `document` (relation `documents`, maxSelect 1, required),
  `group` (relation `groups`, maxSelect 1, required), `right` (select `read`|`write`, required).
  Unique index on `(document, group)`.

Revert deletes the three collections in reverse dependency order.

**`002_core_rules.js`** sets, with `readable = ((document_access_via_document.right ?= "read" || document_access_via_document.right ?= "write") && document_access_via_document.group.members.id ?= @request.auth.id)`:

- `documents.listRule` = `documents.viewRule` = `@request.auth.id != "" && (owner = @request.auth.id || <readable>)`
- `documents.updateRule` = `documents.deleteRule` = `@request.auth.id != "" && (owner = @request.auth.id || (document_access_via_document.right ?= "write" && document_access_via_document.group.members.id ?= @request.auth.id))`
- `documents.createRule` = `@request.auth.id != "" && @request.body.owner = @request.auth.id`
- `groups` and `document_access`: all six rules left `null` (superuser/dashboard only, section 5).
- `users`: `createRule = null` (signup disabled); list/view/update/delete left at the default
  self-only `id = @request.auth.id`.

Rule-form constraint for reviewers: every `document_access_via_document.*` condition inside one
`&&` chain must use that single path; introducing a second path to the same collection inside one
rule reopens the cross-row leak and is rejected in review. A multi-relation membership test must
also use the `.id` form (`document_access_via_document.group.members.id ?= @request.auth.id`): the
unnormalised `group.members ?= ...` form compares the raw JSON array column to a scalar id, silently
denies every group-granted access, and is rejected in review.

## 5. Hooks (`pb_hooks/`)

- **`documents_version.pb.js`**
  - `onRecordCreateRequest('documents')`: set `version = 1` (superuser creates included).
  - `onRecordUpdateRequest('documents')`: superusers skip the expectation check but still get the
    increment (dashboard edits must not desynchronize clients). Others: read
    `e.requestInfo().body.expectedVersion`; if absent or not equal to the original `version`, throw
    `new ApiError(409, "stale write: document version is N")`. Then set `version = original + 1`.
    The hook runs after the update rule refetch, so unauthorized writers get 404 before the hook.
- **`invite.pb.js`**: `POST /nostromo/invite`, `$apis.requireSuperuserAuth()`. Body `{email, name?}`.
  Validates email, lowercases it, `findAuthRecordByEmail` for idempotency, creates with a generated
  16-char password when absent. Response `{email, userId, created, password?}` (`password` only on
  first creation). No membership rows (section 11).
- **`users_enrich.pb.js`**: `POST /nostromo/users/enrich`, `$apis.requireAuth()`. Body `{ids}`
  (max 50, deduplicated, self excluded). Per id, authorized when either filter matches:
  - shared group: `groups` filter `members:each ?= {:caller}`, then a JavaScript check that the
    loaded group's `members` contains `{:target}` (the two-condition
    `members ?= {:caller} && members ?= {:target}` form is wrong: both any-of
    conditions collapse onto one JSON iteration alias, degrading to "caller equals target")
  - readable document owned by target: `documents` filter
    `owner = {:target} && ((document_access_via_document.right ?= "read" || document_access_via_document.right ?= "write") && document_access_via_document.group.members.id ?= {:caller})`
  Response `{users: [{id, name}]}`. Name only, never email.

## 6. Scripts and repo docs

`infra/pocketbase/scripts/` (bash, idempotent, dev credentials only, English messages):

- `download.sh`: pin `VERSION="0.40.4"`, linux/darwin amd64/arm64, skip when the binary already
  reports the version. Never commit the binary.
- `serve.sh`: download if missing, `serve --http=127.0.0.1:8090 --dir pb_data --migrationsDir
  pb_migrations --hooksDir pb_hooks --automigrate=0 --origins http://localhost:3000
  --origins http://127.0.0.1:3000` (dev CORS only).
- `bootstrap.sh`: superuser upsert (`dev@nostromo.local`, fixed dev password, clearly marked DEV
  ONLY), wait for `/api/health`, then idempotently create a first user `app@nostromo.local` through
  the superuser API. Prints the local URLs and credentials warning.
- `smoke.sh`: see task T7.

Repo docs: `docs/deployment.md` (new), README command list plus roadmap tick, small
`infra/pocketbase/README.md` describing the directory and the local workflow.

## 7. Milestones and tasks

Parallelizable tasks are marked **[P]**; strictly ordered dependencies are listed per task.

**T1. Dev scripts** `[P]`
- Goal: `download.sh`, `serve.sh` per section 6.
- Files: `infra/pocketbase/scripts/download.sh`, `serve.sh`.
- Depends on: nothing.
- Acceptance: from a clean clone, `download.sh` fetches 0.40.4 and prints the version; `serve.sh`
  starts, serves health at 127.0.0.1:8090.
- Proof: `bash infra/pocketbase/scripts/download.sh && bash infra/pocketbase/scripts/serve.sh & curl -fsS http://127.0.0.1:8090/api/health`.

**T2. Migrations** `[P]`
- Goal: the three collections plus all rules per sections 4.
- Files: `infra/pocketbase/pb_migrations/001_core_collections.js`, `002_core_rules.js`.
- Depends on: nothing (names are fixed by this plan).
- Acceptance: fresh `pb_data`, migrations apply on serve with no error; dashboard shows the
  collections with the exact fields, indexes and rules above; `users.createRule` is null.
- Proof: start `serve.sh` with an empty `pb_data`, then check the admin UI collection pages, or
  `GET /api/collections/documents/records` returns 400 without auth rather than a rule error.

**T3. Version hook** `[P]`
- Goal: stale-write rejection per section 5.
- Files: `infra/pocketbase/pb_hooks/documents_version.pb.js`.
- Depends on: T2 field names only (parallel-safe).
- Acceptance: create sets `version: 1`; update with matching `expectedVersion` increments; update
  with stale or missing `expectedVersion` returns 409 with the current version in the message;
  superuser update without `expectedVersion` succeeds and increments.
- Proof: covered by smoke checks 6, 14, 15, 16 (T7); ad hoc curl during development.

**T4. Invite hook** `[P]`
- Goal: `/nostromo/invite` per section 5.
- Files: `infra/pocketbase/pb_hooks/invite.pb.js`.
- Depends on: nothing.
- Acceptance: superuser invite returns a password; same email again returns the same `userId`,
  `created: false`, no password; unauthenticated or non-superuser call gets 401/403; no rows appear
  in `groups` or `document_access`.
- Proof: smoke checks 3, 4, and 401 on `curl -X POST .../nostromo/invite` without token.

**T5. Enrich hook** `[P]`
- Goal: `/nostromo/users/enrich` per section 5.
- Files: `infra/pocketbase/pb_hooks/users_enrich.pb.js`.
- Depends on: nothing.
- Acceptance: a caller sharing a group with the target, or able to read a document the target owns,
  gets `{id, name}`; unrelated ids return nothing; email never appears; over 50 ids is a 400.
- Proof: smoke checks 19, 20.

**T6. Bootstrap script** (ordered after T1, T2)
- Goal: `bootstrap.sh` per section 6.
- Files: `infra/pocketbase/scripts/bootstrap.sh`.
- Acceptance: running twice changes nothing; superuser and first user exist; no production-looking
  credentials anywhere in output or file.
- Proof: `bash infra/pocketbase/scripts/bootstrap.sh && bash infra/pocketbase/scripts/bootstrap.sh`.

**T7. Smoke test** (authored `[P]`, executed last)
- Goal: end-to-end contract check, clear PASS/FAIL per line, non-zero exit on any FAIL. Uses curl
  plus python3 for JSON. Runs against the local instance after T6.
- Files: `infra/pocketbase/scripts/smoke.sh`.
- Checks (numbered, each asserted): 1 health; 2 superuser auth; 3 invite alice (password, created
  true); 4 invite alice again (same id, created false); 5 alice auth; 6 alice creates document with
  client id `smoke000000001a` (pattern-valid) plus payload and `owner`, response `version: 1`;
  7 duplicate create with same id fails 400; 8 invite and auth bob; 9 bob view returns 404;
  10 bob list does not contain the document; 11 superuser creates group with bob and a `read`
  access row; 12 bob view returns 200 version 1; 13 bob update (expectedVersion 1) returns 404
  (read-only); 14 alice update (expectedVersion 1) returns 200 version 2; 15 alice update with stale
  expectedVersion 1 returns 409; 16 superuser flips the access row to `write`, bob update
  (expectedVersion 2) returns 200 version 3; 17 alice uploads a file (multipart PATCH), 18 bob
  downloads it with his token and bytes match; 19 bob enrich [alice] returns her name; 20 bob enrich
  of an unrelated id returns empty; 21 unauthenticated document create is rejected.
- Proof: `bash infra/pocketbase/scripts/smoke.sh` exits 0 with all PASS.

**T8. Docs** `[P]`
- Goal: `docs/deployment.md` (target host marius.click behind nginx, one shared instance, per-app
  user separation, `/nostromo/` and `/api/` proxying without prefix rewrite, dev CORS only in
  `serve.sh`, two backup layers: native scheduled PocketBase backups of `pb_data` plus an
  off-machine copy; server configuration itself out of scope), README command list and roadmap tick,
  `infra/pocketbase/README.md`.
- Acceptance: a new contributor can go from clone to smoke-pass with only the README.
- Proof: README run of commands matches reality.

**Validation milestone** (after all tasks): fresh `pb_data`, then `download.sh`, `serve.sh`,
`bootstrap.sh`, `smoke.sh` in sequence, all green. Hooks and rules cannot be unit tested in the
app framework; this smoke run is the closed feedback loop and the gate.

## 8. Risks and failure modes

- **Rule typo silently denies everything.** A wrong back-relation name or operator makes every read
  404 and every list empty, with no server error. Mitigation: smoke checks 9 to 13 pin the exact
  allow and deny matrix; review enforces the single-path rule form of section 4.
- **Hooks bypass rules.** `$app` queries in hooks run with unrestricted access. Invite is
  superuser-gated; enrich hand-implements its authorization (the two filters of section 5) instead of
  trusting the caller. Any new hook must state its authorization in a header comment.
- **Version hook ordering.** The stale check must read `e.record.original()`, not the mutated
  record, and must run the increment before `e.next()`. A superuser path that skips the increment
  desynchronizes every client of that document (smoke does not cover dashboard edits; keep the
  superuser branch simple and increment unconditionally).
- **Migration ordering and drift.** `002` references fields created by `001`; both need correct
  revert functions (reverse order). `serve.sh` pins `--automigrate=0` so dashboard edits never leak
  into `pb_data` silently; shared environments only ever change through migrations (AGENTS.md).
- **Backup and restore.** Copying `pb_data` while the instance runs can capture a torn SQLite state.
  Use the native backup (consistent snapshot) as layer one and copy the backup archive off-machine
  as layer two; document restore = stop instance, replace `pb_data`, start. Server-side cron is out
  of scope.
- **Shared instance, per-app user separation.** One users pool, no per-app tag: any user can
  authenticate to any app hitting the instance. v1 accepts this (section 9); invite being
  superuser-only is what keeps account creation deliberate. Groups are the only sharing boundary.
- **Timestamp trust.** `updated` stays in the API but nothing may branch on it for correctness;
  conflict decisions use `version` only (section 3.5). A client echoing a stale `updated` must not
  regain write access; smoke check 15 proves the 409 path does not consult timestamps.

## 9. Sequencing summary (for the coordinator)

- Wave 1, five parallel implementation workers: T1 scripts, T2 migrations, T3 version hook,
  T4 invite hook, T5 enrich hook, plus T7 smoke authoring and T8 docs (contract is fully specified
  above, no code dependency).
- Wave 2: T6 bootstrap (needs T1 and T2 merged).
- Wave 3: validation worker runs the fresh-clone sequence of the validation milestone; failures go
  back to the owning task as fix items; re-run until green.

Human checks flagged for the owner: H1 enrich returning name only (no email) suffices for apps;
H2 deferring forced password change at first login; H3 the 20 MiB file cap value.

**Status of the human checks (2026-09-14): H1, H2 and H3 were all ACCEPTED by the project owner.**

- **H1 accepted.** The enrich endpoint returns `name` only, with no email. Name only is enough for
  apps to render authors. The decision of section 3.4 stands unchanged.
- **H2 accepted.** Forcing a password change at first login stays deferred. The rationale is
  unchanged: no native PocketBase mechanism exists and a blocking hook risks lockout.
- **H3 accepted.** The 20 MiB file cap is kept as specified in the supporting decisions of
  section 3.

