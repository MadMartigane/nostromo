# Nostromo

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> A shared cargo for your apps. Nostromo is a multi-app backend, powered by [PocketBase](https://pocketbase.io/).

Nostromo is named after the commercial towing vessel from *Alien*: like the ship, this project carries
what your applications need so they can focus on their own mission.

## Why Nostromo?

Several of our applications follow the same pattern:

- They work **offline-first**: all data lives in the browser (localStorage / IndexedDB).
- They offer a manual **import/export** flow to back up or hand over work.

This works fine for a handful of users, but it does not scale. Nostromo provides the missing piece:
a **shared PocketBase backend** handling authentication, data storage, and sync, so each app can move
from "local files" to "real accounts and cloud sync" without owning a backend.

## First client: ballerStats

The first app on board is [ballerStats](https://github.com/MadMartigane/ballerStats), a basketball
statistics collector. Its PocketBase proof of concept defines the initial collections, access rules,
and sync engine that Nostromo generalizes.

## Repository layout

```
nostromo/
├── docs/               # Design documents and analysis
├── infra/
│   └── pocketbase/     # PocketBase setup: migrations, hooks, scripts
├── AGENTS.md           # Guidelines for AI coding agents
├── LICENSE             # MIT
└── README.md
```

## Getting started

Prerequisites: any Linux/macOS/Windows machine with `bash` and internet access for the first run.

```bash
# Download the PocketBase binary (once)
bash infra/pocketbase/scripts/download.sh

# Start PocketBase (serves http://127.0.0.1:8090, applies migrations)
bash infra/pocketbase/scripts/serve.sh

# In another terminal: create the superuser and demo data
bash infra/pocketbase/scripts/bootstrap.sh
```

- Admin UI: http://127.0.0.1:8090/_/
- API: http://127.0.0.1:8090/api/ (docs at http://127.0.0.1:8090/api/docs)

> Everything under `infra/pocketbase/` targets local development. Development credentials and
> demo data must never reach production.

## Documentation

- [PocketBase POC analysis (ballerStats)](docs/pocketbase-poc-analysis.md)

## Principles

- **Offline-first clients**: the backend augments local-first apps, it never replaces their local store.
- **One backend, many apps**: app-specific logic stays isolated (namespaced routes, hooks) so future
  apps can board without touching existing ones.
- **Infra as code**: collections, API rules and hooks are versioned migrations, reproducible from a
  fresh clone.

## Roadmap

- [x] Repository cleanup and project setup
- [ ] BallerStats POC analysis and design decisions
- [ ] Generic multi-app collections model
- [ ] ballerStats backend support (collections, rules, hooks)
- [ ] Production deployment guide

## Contributing

Branching model: `main` is the stable branch, `develop` is the integration branch, features branch
off `develop` as `feat/...`. All written documentation is in English. Commits follow
[Conventional Commits](https://www.conventionalcommits.org/).

## License

[MIT](LICENSE)
