# Nostromo Development Guidelines

> **AI coding agents**: this file is the canonical reference for working in this repository.

## Project

Nostromo is a multi-app backend powered by [PocketBase](https://pocketbase.io/). First client:
[ballerStats](https://github.com/MadMartigane/ballerStats).

## Tech Stack

- **Backend**: PocketBase (latest stable release), Go binary, no framework code
- **Infra as code**: versioned JS migrations (`pb_migrations/`), JS hooks (`pb_hooks/`)
- **Docs**: Markdown in English, in `docs/`
- **Shell**: bash scripts for download/serve/bootstrap

## Repository Layout

```
nostromo/
├── docs/               # Design documents and analysis (English)
├── infra/pocketbase/   # PocketBase migrations, hooks, scripts, README
└── AGENTS.md
```

## Git Conventions

- Branching: `main` (stable), `develop` (integration), `feat/...` off `develop`
- Commits: [Conventional Commits](https://www.conventionalcommits.org/)
- Never commit: `pocketbase` binary, `pb_data/`, `.env`, any `*.zip`

## Documentation Conventions

- All written documentation is in **English**
- Design docs live in `docs/`

## PocketBase Conventions

- Collections, API rules and settings changes go through **versioned migrations** in
  `infra/pocketbase/pb_migrations/`, never through manual Admin UI edits in shared envs
- App-specific custom routes and hooks must be namespaced per app (e.g. `/api/<app>/...`)
  so multiple apps can share the same instance
- Local dev scripts must be idempotent and never create real credentials for production

## Commands

```bash
bash infra/pocketbase/scripts/download.sh    # fetch the PocketBase binary
bash infra/pocketbase/scripts/serve.sh       # run PocketBase locally (127.0.0.1:8090)
bash infra/pocketbase/scripts/bootstrap.sh   # idempotent dev bootstrap (superuser + demo data)
```
