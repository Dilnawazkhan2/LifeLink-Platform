-- ============================================================================
-- LifeLink Platform — 0004: Row Level Security + least-privilege grants
--
-- Model:
--   * RLS is enabled on EVERY table in public.
--   * Table privileges start from zero for anon/authenticated; only what a
--     client legitimately needs is granted back (column-level where useful).
--   * Workflow writes (requests, responses, donations, applications, reviews,
--     roles, availability) go through security-definer RPCs (0005) that
--     validate input and check roles server-side. Clients never write those
--     tables directly.
--   * Public donor discovery never touches the donors table directly; it uses
--     search_donors() which returns non-contact fields only.
-- ============================================================================

-- ── Start from zero ──────────────────────────────────────────────────────────
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end $$;

-- Internal helper functions are NOT callable by clients.
revoke execute on function public.set_updated_at()                   from public, anon, authenticated;
revoke execute on function public.resolve_city(text)                 from public, anon, authenticated;
revoke execute on function public.notify_user(uuid, public.notification_type, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.handle_new_user()                  from public, anon, authenticated;
revoke execute on function public.handle_user_email_change()         from public, anon, authenticated;
revoke execute on function public.audit_row_change()                 from public, anon, authenticated;
revoke execute on function public.on_blood_request_status()          from public, anon, authenticated;
revoke execute on function public.on_request_response()              from public, anon, authenticated;
revoke execute on function public.evaluate_badges(uuid)              from public, anon, authenticated;
revoke execute on function public.on_donation_or_response_badges()   from public, anon, authenticated;

-- Helpers referenced inside policies must be executable by the caller role.
grant execute on function public.has_role(public.app_role)  to anon, authenticated;
grant execute on function public.is_admin()                 to anon, authenticated;
grant execute on function public.is_staff()                 to anon, authenticated;
grant execute on function public.is_active_user()           to anon, authenticated;
grant execute on function public.manages_hospital(uuid)     to anon, authenticated;
grant execute on function public.my_donor_id()              to authenticated;

-- ============================================================================
-- Reference data: readable by everyone
-- ============================================================================
grant select on public.blood_groups, public.cities, public.badges to anon, authenticated;
create policy "reference: read blood groups" on public.blood_groups for select to anon, authenticated using (true);
create policy "reference: read cities"       on public.cities       for select to anon, authenticated using (true);
create policy "reference: read badges"       on public.badges       for select to anon, authenticated using (true);

-- ============================================================================
-- profiles
-- ============================================================================
grant select on public.profiles to authenticated;
grant update (full_name, phone, blood_group, account_type, city_id, area,
              date_of_birth, gender, weight_kg, avatar_path) on public.profiles to authenticated;

create policy "profiles: read own" on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy "profiles: staff read all" on public.profiles
  for select to authenticated using ((select public.is_staff()));
create policy "profiles: update own while active" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()) and status = 'active')
  with check (id = (select auth.uid()));

-- ============================================================================
-- user_roles (writes only via admin RPC)
-- ============================================================================
grant select on public.user_roles to authenticated;
create policy "roles: read own" on public.user_roles
  for select to authenticated using (user_id = (select auth.uid()));
create policy "roles: admin read all" on public.user_roles
  for select to authenticated using ((select public.is_admin()));

-- ============================================================================
-- user_addresses (owner CRUD)
-- ============================================================================
grant select, insert, update, delete on public.user_addresses to authenticated;
create policy "addresses: owner all" on public.user_addresses
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and (select public.is_active_user()));
create policy "addresses: staff read" on public.user_addresses
  for select to authenticated using ((select public.is_staff()));

-- ============================================================================
-- hospital_staff (admin managed via RPC)
-- ============================================================================
grant select on public.hospital_staff to authenticated;
create policy "hospital staff: read own" on public.hospital_staff
  for select to authenticated using (user_id = (select auth.uid()));
create policy "hospital staff: admin read" on public.hospital_staff
  for select to authenticated using ((select public.is_admin()));

-- ============================================================================
-- donor_applications (insert via submit_donor_application RPC)
-- ============================================================================
grant select on public.donor_applications to authenticated;
create policy "applications: read own" on public.donor_applications
  for select to authenticated using (submitted_by = (select auth.uid()));
create policy "applications: staff read" on public.donor_applications
  for select to authenticated using ((select public.is_staff()));

-- ============================================================================
-- donors (contains contact fields → no public read; use search_donors())
-- ============================================================================
grant select on public.donors to authenticated;
grant update (area, hours, about) on public.donors to authenticated;
create policy "donors: read own" on public.donors
  for select to authenticated using (profile_id = (select auth.uid()));
create policy "donors: staff read" on public.donors
  for select to authenticated using ((select public.is_staff()));
create policy "donors: update own profile fields" on public.donors
  for update to authenticated
  using (profile_id = (select auth.uid()) and (select public.is_active_user()))
  with check (profile_id = (select auth.uid()));

-- ============================================================================
-- donor_availability (status is public so the website/app can show it live;
-- writes via set_my_availability / admin RPC)
-- ============================================================================
grant select (donor_id, status, updated_at) on public.donor_availability to anon, authenticated;
create policy "availability: public read" on public.donor_availability
  for select to anon, authenticated using (true);

-- ============================================================================
-- hospitals + inventory (public read; admin / hospital staff write)
-- ============================================================================
grant select on public.hospitals to anon, authenticated;
grant insert, update, delete on public.hospitals to authenticated;
create policy "hospitals: public read active" on public.hospitals
  for select to anon, authenticated using (is_active or (select public.is_admin()));
create policy "hospitals: admin insert" on public.hospitals
  for insert to authenticated with check ((select public.is_admin()));
create policy "hospitals: admin or staff update" on public.hospitals
  for update to authenticated
  using ((select public.manages_hospital(id)))
  with check ((select public.manages_hospital(id)));
create policy "hospitals: admin delete" on public.hospitals
  for delete to authenticated using ((select public.is_admin()));

grant select on public.hospital_inventory to anon, authenticated;
grant insert, update (units) on public.hospital_inventory to authenticated;
create policy "inventory: public read" on public.hospital_inventory
  for select to anon, authenticated using (true);
create policy "inventory: managers insert" on public.hospital_inventory
  for insert to authenticated with check ((select public.manages_hospital(hospital_id)));
create policy "inventory: managers update" on public.hospital_inventory
  for update to authenticated
  using ((select public.manages_hospital(hospital_id)))
  with check ((select public.manages_hospital(hospital_id)));

-- stamp who changed stock
create or replace function public.stamp_inventory_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end $$;
revoke execute on function public.stamp_inventory_update() from public, anon, authenticated;
create trigger hospital_inventory_stamp before insert or update on public.hospital_inventory
  for each row execute function public.stamp_inventory_update();

-- ============================================================================
-- blood_requests (create / transition via RPC; admins may delete)
-- Visible: published requests to signed-in users, own requests, staff all.
-- Anonymous visitors get published requests WITHOUT contact via list_public_requests().
-- ============================================================================
grant select on public.blood_requests to authenticated;
grant delete on public.blood_requests to authenticated;
create policy "requests: read published" on public.blood_requests
  for select to authenticated using (status in ('approved', 'active', 'fulfilled'));
create policy "requests: read own" on public.blood_requests
  for select to authenticated using (requester_id = (select auth.uid()));
create policy "requests: staff read all" on public.blood_requests
  for select to authenticated using ((select public.is_staff()));
create policy "requests: admin delete" on public.blood_requests
  for delete to authenticated using ((select public.is_admin()));

grant select on public.request_status_history to authenticated;
create policy "request history: staff or requester" on public.request_status_history
  for select to authenticated using (
    (select public.is_staff()) or exists (
      select 1 from public.blood_requests r
      where r.id = request_id and r.requester_id = (select auth.uid())
    )
  );

-- ============================================================================
-- request_responses
-- ============================================================================
grant select on public.request_responses to authenticated;
create policy "responses: responder reads own" on public.request_responses
  for select to authenticated using (responder_id = (select auth.uid()));
create policy "responses: requester reads responses to own request" on public.request_responses
  for select to authenticated using (exists (
    select 1 from public.blood_requests r where r.id = request_id and r.requester_id = (select auth.uid())
  ));
create policy "responses: staff read" on public.request_responses
  for select to authenticated using ((select public.is_staff()));

-- ============================================================================
-- donations + badges earned
-- ============================================================================
grant select on public.donations to authenticated;
create policy "donations: donor reads own" on public.donations
  for select to authenticated using (donor_id = (select public.my_donor_id()));
create policy "donations: staff read" on public.donations
  for select to authenticated using ((select public.is_staff()));

grant select on public.user_badges to authenticated;
create policy "user badges: read own" on public.user_badges
  for select to authenticated using (user_id = (select auth.uid()));
create policy "user badges: staff read" on public.user_badges
  for select to authenticated using ((select public.is_staff()));

-- ============================================================================
-- notifications, preferences, push tokens (owner only)
-- ============================================================================
grant select, delete on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy "notifications: read own" on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));
create policy "notifications: mark own read" on public.notifications
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "notifications: delete own" on public.notifications
  for delete to authenticated using (user_id = (select auth.uid()));

grant select on public.notification_preferences to authenticated;
grant update (push_enabled, emergency_alerts, sms_alerts, email_updates,
              show_in_search, share_location, search_radius_km) on public.notification_preferences to authenticated;
create policy "prefs: read own" on public.notification_preferences
  for select to authenticated using (user_id = (select auth.uid()));
create policy "prefs: update own" on public.notification_preferences
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant select, insert, update, delete on public.device_push_tokens to authenticated;
create policy "push tokens: owner all" on public.device_push_tokens
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ============================================================================
-- contact_messages (insert via RPC; staff read / mark read / delete)
-- ============================================================================
grant select, delete on public.contact_messages to authenticated;
grant update (read_at, read_by) on public.contact_messages to authenticated;
create policy "messages: staff read" on public.contact_messages
  for select to authenticated using ((select public.is_staff()));
create policy "messages: staff mark read" on public.contact_messages
  for update to authenticated using ((select public.is_staff())) with check ((select public.is_staff()));
create policy "messages: admin delete" on public.contact_messages
  for delete to authenticated using ((select public.is_admin()));

-- ============================================================================
-- audit + admin activity (admin read only; writes by triggers / RPCs)
-- ============================================================================
grant select on public.audit_logs, public.admin_activity_logs to authenticated;
create policy "audit: admin read" on public.audit_logs
  for select to authenticated using ((select public.is_admin()));
create policy "admin activity: admin read" on public.admin_activity_logs
  for select to authenticated using ((select public.is_admin()));
