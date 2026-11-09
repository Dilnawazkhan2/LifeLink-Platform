# Setup

## 1. Validate the schema (works on this PC today)

```bash
npm install
npm run test:db
```
This applies every migration and seed to an in-process Postgres (PGlite) with a small Supabase stub, then runs 64 security/workflow checks. No Docker needed.

## 2. Local Supabase stack (needs Docker + WSL 2)

Docker Desktop is installed, but **WSL 2 is not**, so Docker cannot run the Linux containers Supabase uses. One-time fix, which needs an administrator PowerShell and a reboot:

```powershell
wsl --install
```

After the reboot, start Docker Desktop, then:

```bash
npm run db:start
```
```bash
npm run db:reset
```

`db:start` prints the local API URL, publishable key and Studio URL (http://127.0.0.1:54323). `db:reset` re-applies migrations + seeds. Local email (password reset) is viewable in Inbucket/Mailpit at http://127.0.0.1:54324.

Dev accounts (local only) are listed at the top of `supabase/seeds/dev_demo.sql`.

## 3. Hosted Supabase project (when ready to go live)

1. Create a free project at https://supabase.com/dashboard (pick a nearby region, e.g. Singapore or Mumbai for Pakistan).
2. From **Project Settings → API**, give me only:
   - **Project URL** (`https://<ref>.supabase.co`)
   - **Publishable key** (or the legacy `anon` key)

   Do **not** share the secret/service-role key or the database password.
3. You run the deploy yourself (it asks for the DB password locally):
   ```bash
   npx supabase@latest login
   ```
   ```bash
   npx supabase@latest link --project-ref <ref>
   ```
   ```bash
   npx supabase@latest db push
   ```
   Then, in the SQL editor, optionally load `supabase/seeds/reference.sql` (hospitals). Never load `dev_demo.sql` in production.
4. Sign up your admin account through the website or app, then run in the SQL editor:
   ```sql
   select public.bootstrap_admin('you@example.com');
   ```
5. In **Authentication → URL Configuration**, set the Site URL to the website domain. Add the redirect URLs for the dashboard and `lifelink://**`.

## 4. Client configuration

| Client | File | Variables |
|---|---|---|
| Website | `config.js` (copy of `env/website.config.example.js`) | `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `ADMIN_DASHBOARD_URL` |
| Admin dashboard | `admin/.env.local` (from `env/admin.env.example`) | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` |
| Android app | `.env.local` in the app repo (from `env/app.env.example`) | `EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `EXPO_PUBLIC_DATA_MODE` |

## 5. Backup and recovery (summary; full runbook in Phase 8)
- Hosted free tier: daily backups for 7 days (Pro plan adds point-in-time recovery).
- Manual logical backups, which use your DB password locally:
  ```bash
  npx supabase@latest db dump -f backups/schema.sql
  ```
  ```bash
  npx supabase@latest db dump --data-only -f backups/data.sql
  ```
- Migrations in git are the schema backup. Restore = `db push` + load the data dump.
