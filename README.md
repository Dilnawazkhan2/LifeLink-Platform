# LifeLink Platform

The shared backend for the **LifeLink** website, admin dashboard and Android app.
One Supabase project = one database, one account system, one set of business rules.

| Doc | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System design and principles |
| [docs/database.md](docs/database.md) | Schema, ER diagram, field mapping from both clients |
| [docs/security.md](docs/security.md) | Auth, roles, RLS matrix, abuse protection, secrets |
| [docs/api.md](docs/api.md) | RPC reference, request status workflow, realtime, client mappings |
| [docs/setup.md](docs/setup.md) | Points to the consolidated guides in the parent folder |

## Layout

```
supabase/migrations/      7 ordered SQL migrations (schema, triggers, RLS, RPC API, realtime, storage, client API)
supabase/seeds/           reference.sql (partner hospitals, safe for production) · dev_demo.sql (LOCAL ONLY demo accounts)
supabase/deploy/          lifelink_schema.sql — every migration + reference data in one file for the Supabase SQL editor
dev-server/               Local Supabase-compatible server on PGlite (no Docker): auth, REST/RPC, realtime, storage
tests/db/                 88 database checks (RLS, workflow, client API) on PGlite
tests/e2e/                94 cross-client checks — the 12 required scenarios driven with the real supabase-js client
tests/cloud/              Read-only verifier for your real Supabase project after deployment
env/                      Example config for each client
```

## Commands

```bash
npm install
```

```bash
npm run dev            # local backend on :54321 + website/admin on :5500 (data persists in dev-server/.data)
```

```bash
npm test               # database checks + end-to-end scenarios
```

```bash
npm run bundle:sql     # regenerate supabase/deploy/lifelink_schema.sql after changing migrations
```

```bash
npm run verify:cloud -- https://YOUR-REF.supabase.co YOUR-PUBLISHABLE-KEY   # after deploying
```

`npm run dev:reset` wipes the local dev data (needed after editing migrations). `npm run dev:memory` runs without saving anything.

The local dev server is for development and testing only. Production runs on a Supabase cloud project. See `SETUP_GUIDE.md` and `DEPLOYMENT_GUIDE.md` in the parent folder.
