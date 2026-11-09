# Authentication, authorization and RLS

## Authentication
- **Supabase Auth** (email + password). Passwords are hashed by Supabase (bcrypt); nothing is stored in plaintext. Minimum length is 8 (`supabase/config.toml`).
- Sessions: the website uses supabase-js browser storage. The app uses AsyncStorage, with auto-refresh paused while backgrounded. The dashboard uses supabase-js browser storage.
- Password reset: `resetPasswordForEmail()`. The redirect URLs allowed are listed in `config.toml` (website, dashboard, `lifelink://` app scheme).
- New users: the `handle_new_user` trigger creates `profiles`, `notification_preferences` and, for donors with blood group + city, a `donors` row. If a website-approved donor with the same email exists, it is **linked** instead of duplicated.

## Roles
| Role | Granted by | Can |
|---|---|---|
| anonymous | — | Submit blood request (pending), donor application, contact message. Search donors (no contact). List published requests (no contact). Read hospitals/inventory. |
| user | sign-up | All of the above, plus own profile, own requests (create/cancel/fulfil), respond, record donations, availability, notifications, reveal donor contact (logged, rate limited) |
| hospital_staff | admin | Update inventory/details of assigned hospitals |
| moderator | admin | Review requests and donor applications, read users/donors/messages, verify donations |
| admin | `bootstrap_admin()` (SQL editor) or another admin | Everything incl. roles, suspension, hospitals, audit logs |

Roles live in `user_roles` and are checked **in Postgres** by `is_admin()`, `is_staff()` and `manages_hospital()`. Client-side checks only hide UI. A suspended profile fails `_require_active_user()`, so every write RPC and owner policy refuses it.

## Privilege model
1. `revoke all` on every table from `anon` and `authenticated`, and default privileges are revoked too.
2. Grant back only what each role needs, using column grants where it matters:
   - `profiles`: users may update name, phone, blood group, account type, city, area, DOB, gender, weight and avatar. They may **not** update `is_verified`, `status` or `email`.
   - `notifications`: update `read_at` only.
   - `donors`: update `area`, `hours` and `about` only.
3. RLS enabled on every table, with policies below.
4. Every function's EXECUTE is revoked, then an explicit allow-list is granted (public API to anon+authenticated, signed-in API to authenticated). Internal helpers (`notify_user`, `resolve_city`, `evaluate_badges`, `bootstrap_admin`, trigger functions) are not callable by clients.

## RLS policy matrix

| Table | anon | authenticated user | staff / admin |
|---|---|---|---|
| blood_groups, cities, badges | read | read | read |
| profiles | — | read/update **own** (allowed columns, while active) | staff read all |
| user_roles | — | read own | admin read all |
| user_addresses | — | full CRUD own | staff read |
| donor_applications | — (insert via RPC) | read own | staff read |
| donors | — (use `search_donors`) | read own; update own area/hours/about | staff read |
| donor_availability | read `donor_id, status, updated_at` | same | same (writes via RPC) |
| hospitals | read active | read active | admin CRUD; hospital staff update own |
| hospital_inventory | read | read | admin / assigned staff insert+update |
| blood_requests | — (use `list_public_requests`) | read approved/active/fulfilled + own | staff read all; admin delete |
| request_status_history | — | own requests | staff |
| request_responses | — | own responses; responses to own requests | staff |
| donations, user_badges | — | own | staff |
| notifications | — | own (read, mark read, delete) | own |
| notification_preferences, device_push_tokens | — | own | own |
| contact_messages | — (insert via RPC) | — | staff read/mark read; admin delete |
| audit_logs, admin_activity_logs | — | — | admin read |
| storage `avatars` | read | write only `avatars/<own uid>/…` | — |

## Abuse protection
- Anonymous blood requests: max 3 per contact number per hour and 60 per 10 minutes overall. Signed-in users: 5 per hour. Every anonymous request starts as **pending** and needs admin review before anyone sees it.
- Donor applications: one pending per email, 60 per 10 minutes overall. Contact messages: 5 per email per hour.
- Donor contact reveals: signed-in only, 30 per user per hour, each one logged in `audit_logs` (`table_name = 'contact_reveal'`).
- For stronger protection before production, add a CAPTCHA on the website forms (Supabase Auth supports hCaptcha/Turnstile). An Edge Function can also add IP-based limits.

## Secrets
- Clients get **only** the project URL and the publishable (anon) key. Both are designed to be public; RLS is what protects data.
- The service-role/secret key and the database password stay in the Supabase dashboard and your own terminal. They must never be pasted in chat, committed or shipped in a client.
- `.env*.local` files are git-ignored. The app's `.env` holds only the public URL and publishable key; EAS cloud builds need it, so it must not be git-ignored.

## Verified behaviour
`npm run test:db` runs 88 checks against the real migrations (PGlite). It covers anonymous access denials, column-level protection, cross-user isolation, the status workflow, admin-only operations, suspension, rate limits, donor de-duplication, notifications and audit logging.
