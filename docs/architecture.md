# Architecture

One Supabase project is the **only** backend for all three clients.

```
                     ┌───────────────────────── Supabase project ─────────────────────────┐
                     │  Postgres 17                                                        │
                     │   • tables + constraints (single source of data)                    │
                     │   • RLS on every table (who may read/write which rows/columns)      │
                     │   • RPC functions = business rules (validation, status workflow,    │
                     │     rate limits, admin actions, audit)                              │
                     │   • triggers: profiles on signup, status history, notifications,     │
                     │     badges, audit_logs                                               │
                     │  Auth (email + password, reset emails, JWT sessions)                │
                     │  Realtime (postgres_changes, filtered by RLS)                        │
                     │  Storage (avatars bucket, owner-folder policies)                    │
                     └────────▲──────────────────────▲─────────────────────▲───────────────┘
              publishable key │ + user JWT            │                     │ user JWT (admin role
                              │                       │                     │ checked in Postgres)
             ┌────────────────┴─────┐   ┌─────────────┴────────┐   ┌────────┴──────────────┐
             │ LifeDrop website     │   │ LifeLink Android     │   │ Admin dashboard        │
             │ static HTML/JS       │   │ Expo SDK 58          │   │ React + Vite + TS      │
             │ db.js → supabase-js  │   │ store → services →   │   │ (Phase 4, this repo:   │
             │ (CDN), same UI       │   │ supabase-js          │   │  admin/)               │
             └──────────────────────┘   └──────────────────────┘   └───────────────────────┘
```

## Principles

1. **One database, one set of rules.** Business logic lives in Postgres functions (`supabase/migrations/*_rpc_functions.sql`). The website, the app and the dashboard all call the same functions. No client duplicates validation that matters.
2. **Clients hold only public keys.** Each client ships the project URL and the **publishable (anon) key**. The secret/service-role key is never in any client; it's only used by you in the Supabase dashboard/CLI.
3. **Deny by default.** All table privileges are revoked from `anon`/`authenticated` and granted back per table and column. RLS is enabled everywhere. Privileged writes are only possible through `security definer` RPCs that re-check the caller's role.
4. **Contact data is protected.** Donor phone and email never leave the database through public paths. `search_donors()` returns discovery fields only. `get_donor_contact()` requires a signed-in active user and is logged.
5. **Realtime is an enhancement, not a dependency.** Every screen loads with a normal query and supports refresh. Realtime subscriptions only patch the data that's already loaded.
6. **Auditable.** Row changes on sensitive tables are captured in `audit_logs` by trigger. Admin actions are written to `admin_activity_logs` with actor, target and details.

## Repository layout

```
LifeLink Platform/
  supabase/
    config.toml                local stack config
    migrations/                ordered SQL migrations (schema, RLS, RPC, realtime, storage)
    seeds/reference.sql        partner hospitals + starting inventory (reviewable for prod)
    seeds/dev_demo.sql         DEV ONLY: demo accounts, requests, donations
  tests/db/                    PGlite harness: applies migrations + 64 RLS/workflow checks
  docs/                        architecture, database, security, API, setup
  env/                         example config for each client
  admin/                       (Phase 4) admin dashboard
  shared/                      (Phase 3+) generated DB types shared by admin + app
```

## Client integration summary

| Client | How it connects | What changes |
|---|---|---|
| Website | `<script>` for supabase-js (CDN) + `config.js` + rewritten `db.js` internals | No HTML/CSS/layout change. Forms call RPCs, auth uses Supabase Auth, donor search uses `search_donors`, output is HTML-escaped. `admin.html` redirects to the dashboard. |
| Android app | `@supabase/supabase-js` + `expo-sqlite` session storage (Expo-documented setup) | `src/services/*` call Supabase; the store loads from the backend; mock data stays only behind an explicit demo flag |
| Admin dashboard | supabase-js with the admin's own JWT | New app; all privileged actions are RPCs that check `is_admin()` / `is_staff()` server-side |

## Request lifecycle

See [api.md](api.md#request-status-workflow). Every status change goes through `transition_request_status()`, which writes `request_status_history`, `admin_activity_logs` and `audit_logs`, and notifies the requester and responders.
