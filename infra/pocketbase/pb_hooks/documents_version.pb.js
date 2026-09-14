// Server-authoritative versioning for `documents` (phase-4-plan.md section 5,
// decisions.md section 6). The numeric `version` field is the only conflict
// token; `updated` is display/audit data and is never consulted here.
//
// Authorization assumptions:
// - This hook performs NO authorization. Access is decided upstream by the
//   `documents` API rules. On update, PocketBase refetches the record through
//   `updateRule` and answers 404 before this hook runs, so only the owner or a
//   write-granted member ever reaches the stale check. Unauthorized writers are
//   therefore rejected with 404 (not 409), which keeps "no access" and "stale
//   write" distinguishable.
// - Superusers (dashboard edits) are trusted: they skip the expectedVersion
//   check but still get the increment, so a dashboard edit never desynchronizes
//   the version clients hold.
//
// Ordering assumptions:
// - The stale check reads the stored version from `e.record.original()`, never
//   from the mutated record, which may already carry a client-supplied value.
// - The increment is applied before `e.next()` so the persisted row carries it.
//
// NB! PocketBase hook callbacks run in an isolated scope: constants are inlined
// per handler on purpose.

onRecordCreateRequest(
  (e) => {
    // A document is born at version 1, superuser creations included.
    e.record.set('version', 1)
    e.next()
  },
  'documents'
)

onRecordUpdateRequest(
  (e) => {
    const original = e.record.original()
    const currentVersion = original ? Number(original.get('version')) : 0

    if (e.hasSuperuserAuth()) {
      e.record.set('version', currentVersion + 1)
      return e.next()
    }

    // Accepts a JSON number or a multipart string; NaN when absent or invalid.
    const body = e.requestInfo().body
    const expectedVersion = body ? Number(body.expectedVersion) : NaN

    if (expectedVersion !== currentVersion) {
      throw new ApiError(409, `stale write: document version is ${currentVersion}`)
    }

    e.record.set('version', currentVersion + 1)
    e.next()
  },
  'documents'
)
