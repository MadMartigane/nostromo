// Nostromo core API rules, resaved (convergence migration).
//
// Why this exists: PocketBase migrations are one-shot. This instance runs with
// `--automigrate=0` and never re-runs an already applied migration, so a database created
// before 002_core_rules.js reached its final rule strings still stores the old form (the
// `group.members` multi-relation containment written without `.id`), which never matches and
// silently denies every group-granted access on `documents`. 002 itself cannot be edited:
// an applied migration is never changed afterwards, it is only superseded by a new one.
// This migration re-applies the exact same rule strings for `documents`, so any existing
// database converges on a fresh run; on an already-correct database it is a no-op
// (idempotent).
//
// `groups`, `document_access` and `users` are intentionally left untouched: their rules
// already match 002 (locked to superusers / self-only). Only `documents` needs the resave.
//
// The rule strings below are byte-identical to the ones in 002_core_rules.js; keep them in
// sync. This file mirrors 002, it does not redefine the rules.

migrate(
  (app) => {
    const authenticated = '@request.auth.id != ""'
    const ownerOrReadable =
      'owner = @request.auth.id || ((document_access_via_document.right ?= "read" || document_access_via_document.right ?= "write") && document_access_via_document.group.members.id ?= @request.auth.id)'
    const ownerOrWritable =
      'owner = @request.auth.id || (document_access_via_document.right ?= "write" && document_access_via_document.group.members.id ?= @request.auth.id)'

    const documents = app.findCollectionByNameOrId('documents')
    documents.listRule = `${authenticated} && (${ownerOrReadable})`
    documents.viewRule = documents.listRule
    documents.createRule = `${authenticated} && @request.body.owner = @request.auth.id`
    documents.updateRule = `${authenticated} && (${ownerOrWritable})`
    documents.deleteRule = documents.updateRule
    app.save(documents)
  },
  (app) => {
    // Restore the same rule strings, not null: this migration supersedes 002, it does not
    // create the rules. Reverting to null would assume 002 never ran. 002's own revert
    // remains the one that clears `documents`.
    const authenticated = '@request.auth.id != ""'
    const ownerOrReadable =
      'owner = @request.auth.id || ((document_access_via_document.right ?= "read" || document_access_via_document.right ?= "write") && document_access_via_document.group.members.id ?= @request.auth.id)'
    const ownerOrWritable =
      'owner = @request.auth.id || (document_access_via_document.right ?= "write" && document_access_via_document.group.members.id ?= @request.auth.id)'

    const documents = app.findCollectionByNameOrId('documents')
    documents.listRule = `${authenticated} && (${ownerOrReadable})`
    documents.viewRule = documents.listRule
    documents.createRule = `${authenticated} && @request.body.owner = @request.auth.id`
    documents.updateRule = `${authenticated} && (${ownerOrWritable})`
    documents.deleteRule = documents.updateRule
    app.save(documents)
  }
)
