// Nostromo core API rules.
//
// The document rules rely on `document_access_via_document`, the back-relation
// from `documents` to `document_access`. `document_access` itself is locked to
// superusers (all rules null), which is safe because rule evaluation for
// `documents` runs with hidden-field access and may traverse that relation.
//
// CRITICAL: inside a single rule expression, every `document_access_via_document.*`
// condition MUST use that one path only. A back-relation resolves to a single
// shared SQL join alias, which keeps `right` and `group.members` evaluated on the
// same access row. Adding a second distinct path to `document_access` inside one
// expression creates a separate join and reopens the cross-row access leak: a
// reader matching one row could then be granted the write right held on another
// row. Do not introduce a second path.
//
// `group.members` is a multi-relation, so its membership test is written as
// `group.members.id ?= @request.auth.id` (the documented PocketBase idiom for
// multi-relation containment). Dropping the `.id` suffix makes the resolver
// compare the raw JSON array column to a scalar id, which never matches and
// silently denies every group-granted access.

migrate(
  (app) => {
    const authenticated = '@request.auth.id != ""'
    const ownerOrReadable =
      'owner = @request.auth.id || ((document_access_via_document.right ?= "read" || document_access_via_document.right ?= "write") && document_access_via_document.group.members.id ?= @request.auth.id)'
    const ownerOrWritable =
      'owner = @request.auth.id || (document_access_via_document.right ?= "write" && document_access_via_document.group.members.id ?= @request.auth.id)'

    {
      const documents = app.findCollectionByNameOrId('documents')
      documents.listRule = `${authenticated} && (${ownerOrReadable})`
      documents.viewRule = documents.listRule
      documents.createRule = `${authenticated} && @request.body.owner = @request.auth.id`
      documents.updateRule = `${authenticated} && (${ownerOrWritable})`
      documents.deleteRule = documents.updateRule
      app.save(documents)
    }

    // Rights plumbing stays superuser/dashboard only.
    for (const name of ['groups', 'document_access']) {
      const collection = app.findCollectionByNameOrId(name)
      collection.listRule = null
      collection.viewRule = null
      collection.createRule = null
      collection.updateRule = null
      collection.deleteRule = null
      app.save(collection)
    }

    {
      // Public signup disabled. The other rules keep PocketBase's default
      // self-only behaviour: a user may only read/update/delete their own record.
      const users = app.findCollectionByNameOrId('users')
      users.listRule = 'id = @request.auth.id'
      users.viewRule = 'id = @request.auth.id'
      users.createRule = null
      users.updateRule = 'id = @request.auth.id'
      users.deleteRule = 'id = @request.auth.id'
      app.save(users)
    }
  },
  (app) => {
    // Reverting to null is only a clean restore when 001_core_collections.js and this file
    // are always applied and reverted as a pair: it assumes the `documents` collection is
    // dropped by 001's own revert. Reverting 002 alone leaves the collection rule-less.
    // 003_core_rules_resave.js supersedes (never edits) these rule strings.
    const documents = app.findCollectionByNameOrId('documents')
    documents.listRule = null
    documents.viewRule = null
    documents.createRule = null
    documents.updateRule = null
    documents.deleteRule = null
    app.save(documents)

    // Restore the PocketBase default for `users` (public signup enabled).
    const users = app.findCollectionByNameOrId('users')
    users.createRule = ''
    app.save(users)
    // groups/document_access rules are already null by default; nothing to revert.
  }
)
