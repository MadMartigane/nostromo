# infra/pocketbase

Everything PocketBase needs to run Nostromo. This directory is the whole backend: there is no
application code, only versioned configuration and scripts.

## Contents

```
infra/pocketbase/
├── pb_migrations/   # versioned JS migrations: collections, fields, indexes, API rules
├── pb_hooks/        # versioned JS hooks: custom routes and record-event logic
├── scripts/         # local dev scripts (download, serve, bootstrap, smoke)
└── README.md
```

Two paths exist at runtime but are **never committed** (see `.gitignore`):

- the `pocketbase` binary, downloaded by `scripts/download.sh` into this directory;
- `pb_data/`, the PocketBase data directory (database, uploaded files, settings), created on first
  serve.

## Local workflow

Run from the repository root:

```bash
# 1. Fetch the pinned PocketBase binary (once, skipped if already present)
bash infra/pocketbase/scripts/download.sh

# 2. Start the instance on 127.0.0.1:8090 (applies migrations, loads hooks)
bash infra/pocketbase/scripts/serve.sh

# 3. In another terminal: create the dev superuser and first user (idempotent)
bash infra/pocketbase/scripts/bootstrap.sh

# 4. End-to-end contract check with clear PASS/FAIL lines
bash infra/pocketbase/scripts/smoke.sh
```

- Admin UI: http://127.0.0.1:8090/_/
- API: http://127.0.0.1:8090/api/

`serve.sh` starts the instance with the repository directories as source of truth:

```
serve --http=127.0.0.1:8090 --dir pb_data --migrationsDir pb_migrations \
  --hooksDir pb_hooks --automigrate=0 \
  --origins http://localhost:3000 --origins http://127.0.0.1:3000
```

The two `--origins` values exist for the local frontend only. Production runs same-origin and needs
no CORS configuration (`docs/deployment.md`).

All scripts are idempotent and use development credentials only. Development credentials and demo
data must never reach production.

## Versioned migrations are the only change path

Collections, fields, indexes, API rules and settings changes go through **versioned migrations** in
`pb_migrations/`. Shared environments are only ever changed that way.

**Never edit collections, rules or settings through the Admin UI in a shared environment.** Such an
edit mutates `pb_data` without a matching migration, cannot be reviewed, and is lost or diverged on
the next environment that runs the migrations from scratch. `--automigrate=0` is set precisely so
that dashboard edits never leak into `pb_data` silently.

Hooks live in `pb_hooks/` and follow the same rule: a change is a versioned file in the repository,
never a dashboard edit. Local development may create the superuser and demo data through the
scripts, since that is runtime data, not configuration.

See `AGENTS.md` for the repository conventions and `docs/phase-4-plan.md` for the design behind the
current collections, rules and hooks.
