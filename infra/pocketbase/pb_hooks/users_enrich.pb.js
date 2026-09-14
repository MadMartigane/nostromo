// POST /nostromo/users/enrich
// Body: { ids: string[] } (the caller's own id is dropped, duplicates are collapsed, max 50)
// Response: { users: [{ id, name }] } -- name only, never the email.
//
// AUTHORIZATION (enforced by this hook, never trusted from the caller):
// a target id resolves only when
//   (a) the caller and the target are members of a common group, meaning a
//       `groups` record whose `members` contains both ids, or
//   (b) the target owns a document the caller can read, meaning a
//       `document_access` row on that document grants `read` or `write` to a
//       group the caller belongs to.
// Unauthorized and unknown ids are silently omitted, so the response never
// leaks whether a user exists.
//
// SECURITY: hook queries run with unrestricted server access ($app bypasses
// every collection rule), so the checks below are the only access control.
// The `users` collection is self-only by rule and `document_access` is
// superuser-locked; both are queried here on purpose and only through these
// explicit filters.
//
// Filter notes (verified live on PocketBase 0.40.4):
// - A multi-relation field is a JSON array column, so plain `members ?= {:id}`
//   compiles to `members = 'id'` and never matches. Membership tests need the
//   `:each` modifier: `members:each ?= {:id}`.
// - Two `:each` conditions on the same field share one json_each join alias,
//   so `members:each ?= {:caller} && members:each ?= {:target}` degrades to
//   "caller is target". The caller's groups are therefore loaded once and the
//   target side of the check is done in JS.
// - The document check keeps `right` and `group.members` on the single
//   back-relation path `document_access_via_document` so both conjuncts are
//   evaluated on the same joined access row. A second path to
//   `document_access` inside the same `&&` chain would reopen a cross-row leak
//   and must not be introduced.
//
// NB! PB hook callbacks run in an isolated scope: every helper below is
// inlined inside the routerAdd handler.

routerAdd(
  'POST',
  '/nostromo/users/enrich',
  (c) => {
    const maxIds = 50
    const callerId = c.auth.id
    const body = c.requestInfo().body

    if (!Array.isArray(body.ids)) {
      throw new ApiError(400, 'body.ids must be an array of user ids')
    }
    // Duplicates collapse; the caller's own id is never a target.
    const targetIds = [...new Set(body.ids.map(String))].filter((id) => id !== callerId)
    if (targetIds.length > maxIds) {
      throw new ApiError(400, `at most ${maxIds} ids per request`)
    }

    // Loaded once per request (limit 0 = all matching records).
    const callerGroups = $app.findRecordsByFilter(
      'groups',
      'members:each ?= {:caller}',
      '',
      0,
      0,
      { caller: callerId }
    )
    const sharesGroupWith = (targetId) =>
      callerGroups.some((group) => (group.get('members') || []).includes(targetId))

    const canReadDocumentOwnedBy = (targetId) => {
      const readable = $app.findRecordsByFilter(
        'documents',
        'owner = {:target} && ((document_access_via_document.right ?= "read" || document_access_via_document.right ?= "write") && document_access_via_document.group.members:each ?= {:caller})',
        '',
        1,
        0,
        { target: targetId, caller: callerId }
      )
      return readable.length > 0
    }

    const users = []
    for (const targetId of targetIds) {
      let target
      try {
        target = $app.findRecordById('users', targetId)
      } catch {
        continue // unknown id: omitted, no existence leak
      }
      if (!sharesGroupWith(targetId) && !canReadDocumentOwnedBy(targetId)) {
        continue
      }
      users.push({ id: targetId, name: target.get('name') })
    }

    return c.json(200, { users })
  },
  $apis.requireAuth()
)
