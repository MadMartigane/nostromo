// Cascade delete on the `document_access` relations (defect fix).
//
// Observed defect: deleting a document that has a `document_access` row was impossible.
// The delete returned HTTP 400 with "Failed to delete record. Make sure that the record is
// not part of a required relation reference." for three different callers: the document
// owner, a group member with write-level access, and the superuser. Deleting the access row
// first and then the document returned 204, which proves the cause: the required relation
// field `document` on `document_access` had no cascade delete (and, same defect class, the
// `group` relation: deleting a group could not succeed either while access rows referenced
// it). Verified on an isolated copy: setting cascade delete makes the delete return 204 and
// removes the referencing access rows.
//
// This migration supersedes 001_core_collections.js instead of editing it: an applied
// migration is never edited, only superseded, and existing development databases must
// converge automatically on the next run. Every other field property (collectionId,
// maxSelect, required) is left untouched.

migrate(
  (app) => {
    setAccessRelationCascadeDelete(app, true)
  },
  (app) => {
    setAccessRelationCascadeDelete(app, false)
  }
)

// Sets the `cascadeDelete` flag on the `document` and `group` relation fields of the
// `document_access` collection. The two fields share the same defect class: both are
// required relations pointing at records that may legitimately be deleted.
function setAccessRelationCascadeDelete(app, cascade) {
  const collection = app.findCollectionByNameOrId('document_access')
  for (const field of collection.fields) {
    if (field.name === 'document' || field.name === 'group') {
      field.cascadeDelete = cascade
    }
  }
  app.save(collection)
}
