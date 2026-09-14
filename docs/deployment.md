# Nostromo Deployment Note

> Status: phase 4 note. Scope decided in `docs/decisions.md` section 9 and restated in
> `docs/phase-4-plan.md` section 6. This note documents the target, the shared-instance choice and
> the backup strategy. It is prose only: the actual server configuration lives elsewhere.

## 1. Scope of this note

Nostromo ships a single Go binary and one data directory. The operational surface is small, but two
kinds of change must not be confused:

- **In this repository**: the pinned PocketBase version, the local launch scripts, the dev CORS
  setting, the migrations and hooks, and this note.
- **Out of this repository**: the server-side configuration. The nginx blocks, the TLS
  certificates, the reverse-proxy mounts and the production CORS posture are a separate server
  configuration step, performed on the host itself. This repository never contains them and never
  automates them.

Nothing in section 3 below should be read as a runbook for editing nginx. It describes the contract
the proxy must implement, so that the server configuration step has an unambiguous target.

## 2. Target host and instance model

- **Target host**: the existing server that already serves `marius.click`, behind nginx.
- **One shared instance for all apps**. A single PocketBase process, a single `pb_data` directory,
  a single user pool. Apps do not get their own process or their own data store.
- **Isolation between apps is by user**. Each app uses a different set of users, and the invite
  endpoint is superuser-only, so account creation stays deliberate. In v1 there is no per-app tag
  on a user: any authenticated user can technically authenticate against any app that reaches the
  instance. This is accepted for v1 (`decisions.md` section 9). Groups are the only sharing
  boundary inside the instance.

## 3. Reverse proxy contract

On each app domain, nginx proxies two mounts to the same PocketBase instance:

- **`/nostromo/`** carries the custom routes. The proxy must **not strip the prefix**. Custom routes
  are registered at their full path, for example `/nostromo/invite` and `/nostromo/users/enrich`, so
  the upstream must receive exactly that path. App-specific routes, if any appear later, follow the
  same full-path rule under `/nostromo/<app>/...`.
- **`/api/`** carries PocketBase's own standard endpoints (records, auth, files, health). The same
  instance serves it.

PocketBase cannot serve its API and dashboard under a rewritten subpath, so the strip-prefix variant
is rejected. Both mounts point at the same process.

**CORS.** In production the app and the API share one origin (the app domain), so no CORS
configuration is needed at all. Cross-origin access is a local-development concern only, and it is
limited to the local serve script: `serve.sh` passes `--origins http://localhost:3000` and
`--origins http://127.0.0.1:3000` for the dev frontend. Production must not replicate that.

## 4. Pinned version and persistence

- **Version**: PocketBase **0.40.4** (the latest stable release checked on 2026-09-14, see
  `docs/phase-4-plan.md` section 2). `infra/pocketbase/scripts/download.sh` pins it and skips the
  download when the binary already reports the pinned version. The binary itself is never committed.
- **Persistence**: everything that must survive a restart lives in `pb_data/` (SQLite database,
  uploaded files, settings). `pb_data/` is gitignored and is the only backup target. The instance is
  started with migrations and hooks pointed at the repository directories and `--automigrate=0`, so
  the on-disk schema only ever changes through the versioned migrations.

## 5. Backups

Two layers, both required.

1. **Native scheduled backup (layer one).** PocketBase's built-in backup capability produces a
   consistent snapshot of `pb_data` and can be scheduled from the dashboard. Copying a live
   `pb_data` directory by hand can capture a torn SQLite state, so the native snapshot is the only
   supported way to take a running backup.
2. **Off-machine copy (layer two).** The backup archive is copied off the host, so a lost or
   corrupted machine does not lose the data. The mechanism (rsync, object storage, cron) is part of
   the server configuration step and is out of scope here.

The server-side schedule and the off-machine transfer are server configuration; this repository
specifies the requirement, not the implementation.

## 6. Restore procedure

Restore is deliberately simple:

1. **Stop the instance.**
2. **Replace `pb_data/`** with the contents of the chosen backup (a native backup archive, or the
   matching off-machine copy).
3. **Start the instance** again, using the same start command and the same migration and hook
   directories.

No schema migration step is involved: the backup already contains the applied schema, and the
migrations in the repository match the pinned version.
