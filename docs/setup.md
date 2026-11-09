# Setup

The complete, step-by-step guides live in the parent folder:

- `../../SETUP_GUIDE.md`: run everything locally (no Docker), then connect to Supabase cloud
- `../../DEPLOYMENT_GUIDE.md`: what needs your involvement (Supabase project, keys, hosting, APK, admin account)
- `../../TESTING_REPORT.md`: what was tested and how

Quick reference:

```bash
npm install
```

```bash
npm run dev
```

```bash
npm test
```

Docker is optional. If you install Docker Desktop + WSL 2 later, the official Supabase CLI stack also works with these migrations (`npx supabase start`, then `npx supabase db reset`), but nothing in this project requires it.
