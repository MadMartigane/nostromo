// Nostromo core collections (structure only).
//
// PocketBase does NOT add `created`/`updated` autodate fields to collections
// created through JS migrations (the dashboard adds them client-side), so both
// are declared explicitly on every collection below.
//
// No API rules are set here: they reference back-relations that only resolve
// once every collection exists, so rules live in 002_core_rules.js.

migrate(
  (app) => {
    const usersCollectionId = '_pb_users_auth_'
    // Fresh field objects on every call: PocketBase mutates the values it is
    // given (it assigns field ids), so shared references must be avoided.
    const createdField = () => ({ name: 'created', type: 'autodate', onCreate: true, onUpdate: false })
    const updatedField = () => ({ name: 'updated', type: 'autodate', onCreate: true, onUpdate: true })

    const documents = new Collection({
      type: 'base',
      name: 'documents',
      fields: [
        {
          name: 'owner',
          type: 'relation',
          collectionId: usersCollectionId,
          maxSelect: 1,
          required: true,
        },
        { name: 'payload', type: 'json' },
        { name: 'file', type: 'file', maxSelect: 1, maxSize: 20971520 },
        { name: 'version', type: 'number', required: true },
        createdField(),
        updatedField(),
      ],
    })
    app.save(documents)

    const groups = new Collection({
      type: 'base',
      name: 'groups',
      fields: [
        { name: 'name', type: 'text', required: true, max: 200 },
        {
          name: 'members',
          type: 'relation',
          collectionId: usersCollectionId,
          maxSelect: 200,
        },
        createdField(),
        updatedField(),
      ],
      indexes: ['CREATE UNIQUE INDEX idx_unq_groups_name ON groups (name)'],
    })
    app.save(groups)

    const documentAccess = new Collection({
      type: 'base',
      name: 'document_access',
      fields: [
        {
          name: 'document',
          type: 'relation',
          collectionId: documents.id,
          maxSelect: 1,
          required: true,
        },
        {
          name: 'group',
          type: 'relation',
          collectionId: groups.id,
          maxSelect: 1,
          required: true,
        },
        {
          name: 'right',
          type: 'select',
          required: true,
          maxSelect: 1,
          values: ['read', 'write'],
        },
        createdField(),
        updatedField(),
      ],
      indexes: [
        'CREATE UNIQUE INDEX idx_unq_document_access ON document_access (document, group)',
      ],
    })
    app.save(documentAccess)
  },
  (app) => {
    // Reverse dependency order: document_access references documents and groups.
    for (const name of ['document_access', 'groups', 'documents']) {
      try {
        app.delete(app.findCollectionByNameOrId(name))
      } catch {
        // already deleted, ignore
      }
    }
  }
)
