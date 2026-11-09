# LifeLink Platform

Shared backend for **LifeDrop** (website) and **LifeLink** (Android app), plus the admin dashboard.
One Supabase project = one database, one auth system, one set of business rules.

| Doc | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System design and principles |
| [docs/database.md](docs/database.md) | Schema, ER diagram, field mapping from both clients |
| [docs/security.md](docs/security.md) | Auth, roles, RLS matrix, abuse protection, secrets |
| [docs/api.md](docs/api.md) | RPC reference, request status workflow, realtime, client mappings |
| [docs/setup.md](docs/setup.md) | Local/hosted setup, credentials, backups |

```bash
npm install
npm run test:db      # apply migrations to PGlite + 64 RLS/workflow checks
```

Status: Phase 2 (backend design) complete. Migrations are written and verified with PGlite. They have not yet been applied to a real Supabase instance (local Docker needs WSL 2; hosted needs a project).
