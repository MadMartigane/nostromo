# App Integration Handoff (Nostromo core)

> Audience: the engineer adapting an app to the Nostromo core, starting with ballerStats.
> The decisions behind this contract are in `docs/decisions.md`. Nothing here requires core code;
> if the core contract seems to be missing, stop and raise it instead of working around it.

## 1. Integration contract

- **Base path.** The core is mounted at `/nostromo/` on the app's own domain. The app talks to one
  origin. Whether the reverse proxy strips the prefix is a deployment detail, not your concern.
- **Authentication.** PocketBase SDK, email and password. Public signup is disabled. Accounts are
  created by the invite endpoint (`/nostromo/invite`), which returns the generated password once,
  to the caller, who transmits it out of band. Keep graceful degradation: the app stays usable
  offline when the backend is unreachable.
- **Documents.** Create, update, and list against the core `documents` collection, using
  PocketBase's standard record endpoints. No app-specific routes exist.
- **Document ids are generated client-side** and must match PocketBase's id pattern (15 lowercase
  alphanumeric characters). This makes creates idempotent: a retried create cannot duplicate data.
- **Realtime.** Subscribe to `documents` and pull on change events.
- **File attachment.** Optional, one file per document, via the standard PocketBase file field.
  What the file means (photo, export, anything else) is app policy.
- **Listing.** A list call returns only what the caller's rights allow. There is no separate
  rights endpoint: if a document is not in the list, the app cannot read it.

## 2. Sync engine rewrite

The unit of sync becomes the document. Against the POC engine, this removes and changes the
following.

**Removed (ids are client-generated, so the machinery is dead weight):**

- the id map,
- server-id write-back after create,
- identity rewriting (re-keying local records),
- foreign-key rewriting across pushed records,
- photo blob moves tied to identity rewrites.

**Changed:**

- **Version tracking is per document**, against the server `updated` field. The app no longer
  maintains numeric `updatedAt`/`deletedAt` clock fields for the server contract.
- **Stale writes are rejected** by a server-side check. The app must handle the rejection:
  re-pull, re-apply, or surface the conflict to the user. Last-write-wins survives only as the
  automatic merge rule when no rejection is involved.
- **Outbox is keyed by document id.** One pending item per document, retried safely thanks to
  idempotent creates.
- **Push order is whatever the app's payload graph requires**, if any. The core imposes none.

## 3. Owned by the app, deliberately open

These are design spaces Nostromo leaves to each app. Do not wait for a core decision on them.

- **Document granularity.** Whole state in one document, one document per element, or anything in
  between. Both are valid uses of the contract.
- **The app's own data model.** The payload is opaque to the core.
- **Which group labels its rights use.** Rights in v1 are set by hand in the PocketBase dashboard
  (see below). The app must know which group labels its documents' access rows use, as a
  convention.
- **Photo policy.** The core offers an optional file attachment. Dual storage, thumbnails, upload
  and download decision tables are app-side.
- **Tombstone policy.** If the app wants soft deletes, it keeps tombstone documents. The core has
  no deleted flag in its contract.
- **First-sync UX.** Merge, adopt-remote, or ask the user. The app decides.

## 4. Rights during v1

Rights management happens by hand in the PocketBase dashboard: the superuser grants document
access rows to groups. Consequences for the app:

- the app needs no rights-management endpoints and ships no rights UI,
- but it must know which documents to fetch: the listing call returns what it may read, and that
  is the only discovery mechanism.

## 5. Obsolete, dropped from the earlier plan

- **Server-side player/team junction.** Membership is payload content at app-chosen granularity.
- **Server schema naming and typing cleanup** (`nicName`, `birthDay`, `contacts.playerId`). There
  is no app schema on the server anymore.
- **Club identity binding through the id map.** The id map is gone, and a club is just a document.
- **Team membership created by the invite.** The core invite stops at user creation.
