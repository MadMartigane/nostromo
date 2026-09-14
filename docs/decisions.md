# Nostromo Design Decisions

> Status: **phase 3 output**. Every decision below was validated by the project owner on 2026-09-13.
> Companion documents: `docs/pocketbase-poc-analysis.md` (historical POC analysis, drifts D1 to D10)
> and `docs/app-integration-handoff.md` (the app-side work that follows from these decisions).

## 1. The reframing

Nostromo is not a port of the POC schema. Nostromo is a generic backend whose entire contract is:

1. authentication of users,
2. file storage,
3. answering "may user X access document Y: yes or no".

Nostromo has zero knowledge of any app's data structure. Document content and document granularity
are 100% the app's responsibility: an app may store its whole state in one document, or one document
per element, and Nostromo neither knows nor cares. Apps are pure clients.

Dependency rule: the core never references an app. An app may reference the core.

## 2. Scope boundary

**Core** (generic, no app knowledge):

- users and authentication,
- documents (opaque payload, optional attached file),
- groups and document access rights,
- invite (user creation),
- users enrichment,
- stale-write rejection,
- deployment basics.

**App** (per app):

- its own data model,
- its own document granularity and slicing,
- its own sync engine,
- its own photo policy,
- its own permission mapping (which group labels mean what for this app),
- its own UI.

## 3. Document model

**Decision.**

- One core collection, `documents`, carrying three things: an app-provided id, an opaque JSON
  payload, and an optional attached file.
- The core never interprets the payload. It stores it, versions it, and gates access to it.
- Document ids are generated client-side. PocketBase accepts client-provided record ids that match
  its id pattern (15 lowercase alphanumeric characters).

**Rationale.** The opaque payload is what makes the core generic; any structure the server would
impose is app knowledge leaking in. Client-generated ids remove the asymmetry between local and
server identity that forced the POC to build its heaviest machinery.

**Consequences.**

- Creates become idempotent: retrying a create with the same id cannot duplicate data.
- Four POC mechanisms are no longer needed: server-id write-back, the legacy id map, foreign-key
  rewriting, photo blob moves.

## 4. Access control

**Decision.**

- Two core collections: `groups` (a name plus its member users) and one relation table
  `document_access` with three columns: document, group, right. A document may belong to several
  groups.
- Rights levels: two for v1, read and write. An admin level will be added when a rights-management
  interface exists.
- Authorization semantics for a read: select the `document_access` rows of that document carrying
  read-or-more, collect the resulting groups, and check whether the user is a member of one of
  them.
- Read right and group membership must be evaluated on the same row.

**Rationale.**

- A naive server-side expression can mix two different rows, one granting read and one holding
  membership, and thereby grant write to a reader. The exact API-rule form that prevents this
  cross-row leak is validated in phase 4.
- "Group" is pure server-side rights plumbing, deliberately decoupled from the app's own concepts.
  A club is an app concept and is itself stored as a document like anything else.
- The app never sees nor manages groups. Group names are opaque labels chosen by whoever manages
  rights, for example `admin_cappelle` or `coach_cappelle_u13`.

**Consequences.** Permission mapping is app-side: the core only stores and evaluates access
rows, and adding a new category of reader is a data change on groups, not a code change.

## 5. Core security, v1

**Decision.**

- Any authenticated user can create documents. Apps must be able to store their state.
- A document is private by default: visible only to its creator until rights are granted.
- Rights are managed by hand in the PocketBase dashboard in v1. No rights-management endpoints, no
  admin UI. The superuser performs administrative tasks.
- Rate limiting: PocketBase defaults in v1, to be hardened later.

**Rationale.**

- The first users are few and known. Hand-managed rights in the dashboard cover v1 without building
  an interface nobody has validated yet.
- Private by default keeps the failure mode closed: a misconfigured document is invisible, not
  public.

**Consequences.** Rights changes are manual operations until the admin level and its interface
exist.

## 6. Conflict handling (drift D1, option B)

**Decision.**

- Server-authoritative. PocketBase's native `updated` field is the version reference.
- A generic server-side check rejects stale writes. The exact status code is confirmed in phase 4.
  The contract today is "a stale write is rejected", not a specific code.
- The client keeps last-write-wins only for automatic merge and must handle the rejection: re-pull,
  re-apply, or surface the conflict to the user.
- The app no longer maintains its own numeric `updatedAt`/`deletedAt` clock fields for the server
  contract.
- Tombstones are the app's own business. An app may keep tombstone documents if it wants them.

**Rationale.** One clock, the server's. Two clocks, the app's epoch-ms numbers and the server
`updated`, are exactly what drift D1 flagged as schema bent to legacy shapes. Deletion semantics
are not the core's to define: whether a payload says "deleted" is payload content.

**Consequences.**

- Every app write is checked against the server `updated` of the targeted document.
- Every app must implement one rejection path: re-pull, re-apply, or a user-facing conflict.

## 7. Routes (drift D4)

**Decision.**

- No `/api/` prefix for custom routes.
- External contract on each app domain: `/nostromo/invite` and `/nostromo/users/enrich` for generic
  services, plus PocketBase's own standard endpoints for documents and auth.
- The reverse-proxy mount of `/nostromo/` on the app domain provides the generic namespace. The
  proxy must **not** strip the prefix (the authoritative note is `docs/deployment.md` section 3):
  custom routes are registered at their full path, so the upstream must receive `/nostromo/...`
  unchanged.
- Inside the PocketBase code, app-specific routes are namespaced per app, for example
  `/nostromo/ballerstats/...`, so several apps can coexist without collision.

**Rationale.** Apps integrate against their own domain: one origin, no CORS gymnastics between an
app origin and a shared API origin. The `/nostromo/` prefix names the shared backend without
implying PocketBase's internal `/api/` layout.

**Consequences.**

- The external surface is two custom endpoints plus standard PocketBase. Everything else is
  collections and rules.
- App-specific routes, if any appear later, carry the app name to avoid collisions.

## 8. Invite (drift D5, option a)

**Decision.**

- v1 has no SMTP. Public signup stays disabled.
- The invite endpoint creates the user with a randomly generated password returned once in the
  response to the caller, who transmits it out of band.
- Idempotent on email: inviting an already-invited email does not create a second account.
- SMTP, covering invite by mail and password recovery, is deferred to a later phase.
- Recommended small addition for v1: force a password change at first login.

**Rationale.**

- No mail infrastructure exists yet, and the caller, a known administrator, can hand over a
  password through an existing channel.
- Forcing a change at first login limits the lifetime of the transmitted password.

**Consequences.** The core invite stops at user creation: it creates no membership rows of any
kind, see the reclassification section.

## 9. Deployment (drift D9)

**Decision.**

- PocketBase pinned to the latest stable (0.40.4 at the time of writing), single Go binary, one
  `pb_data` directory to persist.
- One shared instance for all apps. Isolation between apps is by user: each app uses different
  users.
- Target host: the existing server serving marius.click, behind nginx.
- Server-side configuration (nginx, TLS, per-app path mount, CORS in production) is out of this
  repo and will be done later as a server configuration step.
- What stays in this repo: the pinned version, local launch scripts, dev CORS, and a short
  deployment note documenting the target, the shared-instance choice, and the automatic backup of
  `pb_data`.
- Automatic backups of `pb_data` (native PocketBase capability) plus an off-machine copy.

**Rationale.**

- One binary and one data directory is the whole operational surface of the core.
- A shared instance with per-app users avoids multiplying processes and data stores while keeping
  the apps' user bases disjoint.

**Consequences.** Backup is two layers: native scheduled backups plus a copy off the machine.

## 10. Sync engine location (drift D8, option a)

**Decision.**

- The sync engine stays per app for now. It will be extracted into a shared package when a second
  app needs it.
- Nostromo publishes only the contract: documented, no code.

**Rationale.**

- One consumer does not justify a shared abstraction. The document contract, client ids, server
  `updated`, rejection handling, is the stable part worth publishing now.

**Consequences.** Each app owns its outbox, pull loop, and merge policy against the documented
contract.

## 11. Reclassified as app-internal

These items were discussed as server concerns during the POC analysis. They are not part of the
Nostromo contract anymore.

- Player/team membership model (drift D2). The core stores opaque documents. Membership lives in
  payloads, at whatever granularity the app chooses.
- Server schema naming and typing cleanup (drift D6: `nicName`, `birthDay`, `contacts.playerId`).
  There is no app schema on the server to clean up.
- Photo storage pattern (drift D7). The core provides an optional file attachment. Dual-storage
  decisions belong to the app.
- Club resolution and identity binding (drift D3). A club is an app concept stored as a document.
- The POC's invite created team membership rows. In the pivot, the core invite stops at user
  creation.

## 12. Kept from the POC

- PocketBase API rules as the security backbone.
- Authentication through the PocketBase SDK with graceful degradation when the backend is
  unreachable: the app stays usable offline.
- Per-unit conflict granularity, now per document.
- Realtime-driven pulls.
- Outbox and snapshot approach on the client.
- Migrations as code. Idempotent dev bootstrap.
- The invite flow with the password returned once.
- The users enrichment endpoint.
- The photo synchronization pattern, documented as an app-side pattern.

## 13. Open items to validate in phase 4

1. PocketBase `updated` precision and the tie-break rule when values are equal.
2. The exact API-rule form that prevents the cross-row access leak, with read right and group
   membership evaluated on the same row.
3. Confirmation that PocketBase accepts client-provided ids, and the exact id pattern.
4. Whether the core still needs the users-enrichment endpoint, and in what shape.
5. The exact rejection status code for stale writes.
