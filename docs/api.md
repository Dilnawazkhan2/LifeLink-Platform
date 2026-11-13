# API reference

All clients use supabase-js. "RPC" means `supabase.rpc(name, args)`. Errors come back as `{ error: { code, message } }`. The message is user-friendly and can be shown as-is.

| SQLSTATE | Meaning |
|---|---|
| `22023` | invalid input (message names the field) |
| `42501` | not signed in / not allowed / suspended |
| `P0002` | not found |
| `54000` | rate limited |

## Public (anonymous or signed in)

| RPC | Args | Returns | Used by |
|---|---|---|---|
| `submit_blood_request` | `p jsonb`: `patient_name`, `blood_group`, `units?`, `urgency?` *or* `urgent?`, `hospital_id?` *or* `hospital_name` + `city`/`city_id`, `hospital_address?`, `contact_name?`, `contact_phone`, `description?`, `needed_by?`, `source?` | `{id, reference_code, status}` | website form, app Create Request |
| `submit_donor_application` | `p jsonb`: `full_name, email, phone, age, gender, blood_group, city` | `{id, status}` | website donor form |
| `submit_contact_message` | `p jsonb`: `first_name, last_name?, email, phone?, message` | `uuid` | website contact form |
| `search_donors` | `_blood_group?, _city?, _query?, _available_only?, _sort? (donations\|rating\|recent), _limit?, _offset?` | donor rows **without contact** + `total_count` | website search, app Donors tab |
| `get_donor_public` | `_donor_id` | donor profile without contact | app donor profile |
| `list_public_requests` | `_blood_group?, _city?, _urgent_only?, _include_fulfilled?, _limit?, _offset?` | published requests **without contact** | anonymous listings |
| `public_stats` | — | `{donors, available_donors, hospitals, cities, lives_saved, open_requests}` | optional |

| `list_hospitals` | `_city?, _id?` | hospitals with city name and an `inventory` object (`{"O+": 12, …}`); admins also see inactive ones | admin dashboard, app Hospitals |
| `get_donor_details` | `_donor_id` | public donor profile incl. age, about, member since (no contact) | app donor profile |

## Signed-in users

| RPC / table | Purpose |
|---|---|
| `get_my_profile()` | Profile + city name + roles + donor (availability, rating) + notification preferences |
| `update_my_profile(p jsonb)` | Edit own profile: `full_name, phone, blood_group, city` (name), `area, account_type, date_of_birth, gender, weight_kg, avatar_path, hours, about`. Keeps the donor row in sync. A donor account (donor / both) gets its donor record as soon as it has a blood group and a city, whichever fields the save includes (migration 0008); errors are not swallowed |
| `list_requests(_scope 'feed'/'mine', _id?, _limit?)` | App feed: published + own requests, with `city`, `responded_count`, `is_mine`, `my_response` and contact details |
| `list_my_donations()`, `list_my_badges()` | Donation history (with city); all badges with `earned_at` / `progress` |
| `get_my_summary()` | Home/Profile header: donations, lives saved, accepted, my requests, open + urgent counts, unread, badges, availability, last donation, next eligible, `is_admin`, `is_staff` |
| `from('profiles').update({...}).eq('id', me)` | Edit own profile (allowed columns only) |
| `register_as_donor(_blood_group?, _city?, _area?)` | Become a donor |
| `set_my_availability(_status, _note?)` | available / resting / busy |
| `from('blood_requests').select(...)` | Published + own requests (RLS) |
| `respond_to_request(_request_id, _message?)` / `withdraw_response(_request_id)` | Respond to a request / take it back |
| `record_donation(_request_id?, _hospital_name?, _hospital_id?, _donated_on?, _units?)` | Self-reported donation (56-day rule, sets status resting) |
| `transition_request_status(_request_id, _to, _reason?)` | Requester: cancel own request, or mark it fulfilled |
| `get_donor_contact(_donor_id)` | Reveal phone (logged, rate limited) |
| `from('notifications')` select / `update({read_at})` / delete; `mark_all_notifications_read()` | Notifications |
| `from('notification_preferences').update(...)` | Settings |
| `from('donations')`, `from('user_badges')`, `from('badges')` | History, badges |

## Admin / moderator

| RPC | Role |
|---|---|
| `admin_dashboard_stats()` | staff |
| `admin_list_requests(_status?, _source?, _blood_group?, _city?, _search?, _urgency?, _limit?, _offset?)` → `{total, rows}` | staff |
| `admin_get_request(_id)` → request + requester + status history + donor responses | staff |
| `admin_list_donors(_search?, _blood_group?, _availability?, _active?, _limit?, _offset?)` → `{total, rows}` (incl. contact) | staff |
| `admin_list_users(_search?, _role?, _status?, _limit?, _offset?)` → `{total, rows}` (incl. roles) | staff |
| `admin_list_applications(_status?, _search?, _limit?)` | staff |
| `admin_list_logs(_kind 'activity'/'audit', _table?, _limit?, _offset?)` | admin |
| `admin_upsert_hospital(p jsonb)` → id. Create: admin. Edit: admin or that hospital's staff. New hospitals get 8 inventory rows | admin / hospital staff |
| `admin_delete_request(_id)`, `admin_delete_application(_id)` (reviewed applications only) | admin |
| `admin_send_notification(_audience 'user'/'donors'/'all', _title, _body, _user_id?, _city?, _blood_group?)` → number of recipients | staff |
| `transition_request_status(id, to, reason)` | staff: approve, reject (reason required), activate, fulfil, cancel |
| `admin_review_donor_application(id, approve, note?)` | staff |
| `admin_set_donor_active(id, active, reason?)` / `admin_set_donor_availability(id, status)` | staff |
| `admin_verify_donation(id)` | staff |
| `admin_set_verified(user_id, verified)` | staff |
| `admin_set_user_role(user_id, role, grant)` | admin (cannot remove own admin role) |
| `admin_set_account_status(user_id, status, reason)` | admin (reason required to suspend; not self) |
| `admin_assign_hospital_staff(user_id, hospital_id, assign)` | admin |
| `set_hospital_inventory(hospital_id, blood_group, units)` | admin or assigned hospital staff |
| `from('hospitals')` insert/update/delete | admin (staff: update own hospital) |
| `from('audit_logs')`, `from('admin_activity_logs')` | admin read |

Bootstrap the first admin once, from the Supabase SQL editor (not callable by clients):
```sql
select public.bootstrap_admin('your-admin-email@example.com');
```

## Request status workflow

```
pending ──approve──▶ approved ──activate──▶ active ──fulfil──▶ fulfilled
   │                    │                      │
   ├──reject──▶ rejected◀──reject──┘           │
   └─────────cancel────────▶ cancelled ◀───────┘
```

| From → To | Staff | Requester (own) |
|---|---|---|
| pending → approved / rejected | ✓ (reject needs reason) | — |
| pending → cancelled | ✓ | ✓ |
| approved → active / rejected | ✓ | — |
| approved → fulfilled (published requests already accept donors) | ✓ | ✓ |
| approved → cancelled | ✓ | ✓ |
| active → fulfilled | ✓ | ✓ |
| active → cancelled | ✓ | ✓ |
| fulfilled / rejected / cancelled → * | terminal | terminal |

Initial status:

| Submitted by | Starts as |
|---|---|
| Anonymous (website) | `pending` |
| Signed-in, unverified | `pending` |
| Signed-in, verified (`profiles.is_verified`) | `active` (goes live immediately) |

Visibility:

| Who | Sees |
|---|---|
| Anonymous | `approved` and `active` (no contact details) |
| Signed-in | `approved`, `active` and `fulfilled`, plus their own requests in any status |
| Staff | Everything |

Side effects of every transition (trigger):
- writes `request_status_history`
- notifies the requester
- on fulfilled/cancelled, notifies responders
- on → active, notifies compatible available donors in the same city who have alerts enabled (max 500)
- writes `audit_logs`; staff actions also write `admin_activity_logs`

## Realtime channels

| Table | Subscribers |
|---|---|
| `blood_requests` | dashboard (all), app (published + own) |
| `request_responses` | requester, dashboard |
| `donor_availability` | website search, app Donors tab, dashboard |
| `hospital_inventory` | app Hospitals, dashboard |
| `notifications` | each user's own |
| `donor_applications`, `contact_messages` | dashboard |

Realtime applies the same RLS, so a subscriber only receives rows it is allowed to select. Clients always do an initial fetch and support pull-to-refresh / reload; realtime only patches loaded data.

## Website `LifeLinkDB` → backend mapping (Phase 5)

| Existing call | New implementation |
|---|---|
| `users.register` | `auth.signUp({ email, password, options: { data: { first_name, last_name, user_type } } })` |
| `users.login` / `logout` / `getSession` | `auth.signInWithPassword` / `auth.signOut` / `auth.getSession` |
| "Forgot password?" link | `auth.resetPasswordForEmail` (link wired in script.js; no markup change) |
| `donorRequests.create` | `rpc('submit_donor_application')` |
| `requests.create` | `rpc('submit_blood_request')` |
| `messages.create` | `rpc('submit_contact_message')` |
| `donors.search` / `getAll` | `rpc('search_donors', { _available_only: true })`; phone shown only to signed-in users via `get_donor_contact` |
| `admin.html` | Is the admin dashboard (same dark design) behind a login gate; logic in `admin.js`; every action is an RPC re-checked in Postgres |

## App store action → backend mapping (Phase 6)

| Store action | Backend |
|---|---|
| login / logout | `auth.signInWithPassword` / `auth.signOut` (+ new Register screen) |
| updateUser | `profiles.update` + avatar upload to `avatars/<uid>/` |
| setAvailability | `set_my_availability` |
| createRequest | `submit_blood_request` (`source: 'android'`) |
| respondToRequest / withdrawResponse | `respond_to_request` / `withdraw_response` |
| markRequestFulfilled / deleteRequest | `transition_request_status(…, 'fulfilled' \| 'cancelled')`  (users cancel; only admins hard-delete) |
| recordDonation | `record_donation` |
| notification actions | `notifications` table + `mark_all_notifications_read` |
| updateSettings | `notification_preferences.update` |
| donors / hospitals screens | `search_donors`, `get_donor_details`, `get_donor_contact` (signed-in, logged), `list_hospitals` |

## GPS, maps and emergency alerts (migration 0009)

| Function | Who | Notes |
|---|---|---|
| `nearby_donors(_lat, _lng, _radius_km ∈ 5/10/25/50, _blood_group?, _limit?)` | anon, authenticated | Opted-in donors (`nearby_discovery`) with a stored location; `approx_lat/approx_lng` rounded to 2 decimals and `distance_km` measured from the rounded point. No phone/email/exact coordinates |
| `list_request_locations(_lat?, _lng?, _radius_km?, _limit?)` | anon, authenticated | Published (approved/active) requests with a location, rounded to ~100 m, no contact details |
| `submit_blood_request(p)` | anon, authenticated | Also accepts `latitude`, `longitude`, `location_label`; a known `hospital_id` lends its coordinates |
| `set_nearby_discovery(_enabled)` | authenticated | Explicit opt-in; turning it off deletes the stored position |
| `set_my_location(_lat, _lng, _accuracy_m?, _source 'gps'/'manual')` / `clear_my_location()` | authenticated (donor accounts) | Requires the opt-in |
| `register_push_token(_token, _platform)` / `unregister_push_token(_token)` | authenticated | Expo push tokens; a token moving to another account is reassigned |
| `admin_get_alert_settings()` / `admin_update_alert_settings(p)` | staff / admin | radius, escalation radii, minimum donors, max per request, cooldown, on/off, dispatch URL |
| `admin_alert_stats(_days)`, `admin_list_alert_failures(_limit)`, `admin_list_live_requests_with_alerts()` | staff | Delivery statistics, failures, live requests with alert counts |
| `_claim_queued_alerts`, `_complete_alerts`, `_alert_dispatch_secret` | service_role only | Used by the `send-emergency-alerts` Edge Function |

Alert matching (trigger on first publish): compatible blood group, available, active donor and profile, `push_enabled`
(+ `emergency_alerts` unless normal urgency), not the requester; with request coordinates → opted-in donors within the radius,
widening through the escalation radii until the minimum is met; without coordinates → same city. One alert per donor per
request; donors pushed within the cooldown → `skipped`; no device → `no_device`.
