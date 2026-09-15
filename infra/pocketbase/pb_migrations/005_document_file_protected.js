// Protect document files server-side.
//
// v1 shipped the `file` field UNPROTECTED: the file URL was a capability. A v1 audit observed
// that anyone holding a document's file URL could fetch the bytes anonymously with no
// authentication at all, regardless of the document's access rules, because the record's view
// rule does not gate the file endpoint for an unprotected field. The v1 decision (2026-09-15)
// is to protect the file field so that a download goes through the same viewRule as the record.
//
// Protected semantics (verified live on PocketBase 0.40.4): a `protected: true` file field makes
// downloads require a short-lived file token obtained from POST /api/files/token (sent with the
// caller's Authorization header) and passed as `?token=...` on the file URL. A plain
// Authorization header is NOT sufficient. Access stays VIEW-RULE-BASED: any caller satisfying
// the collection's viewRule gets the file, owner or group-granted reader alike, and a valid token
// never bypasses a failing viewRule. Anonymous callers get 404. Because access is view-rule based,
// the existing group grants on `document_access` keep working for readers unchanged.
//
// This migration supersedes 001_core_collections.js instead of editing it: an applied migration is
// never edited, only superseded, and existing development databases must converge automatically on
// the next run. Every other field property (collectionId, name, maxSelect, maxSize, required) is
// left untouched, and only the `file` field is affected.
//
// 004_document_access_cascade.js and this file must be applied in order (004 before 005): 005 only
// flips file protection and assumes the access/cascade plumbing 004 established is already in
// place. Never reorder them.

migrate(
  (app) => {
    setFileProtected(app, true)
  },
  (app) => {
    setFileProtected(app, false)
  }
)

// Sets the `protected` flag on the `file` field of the `documents` collection. Reverting to
// `false` restores the v1 capability-URL behaviour exactly.
function setFileProtected(app, protectedFlag) {
  const collection = app.findCollectionByNameOrId('documents')
  for (const field of collection.fields) {
    if (field.name === 'file') {
      field.protected = protectedFlag
    }
  }
  app.save(collection)
}
