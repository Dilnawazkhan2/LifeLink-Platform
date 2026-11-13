-- ============================================================================
-- LifeLink Platform — 0009: GPS locations, nearby donors, emergency push alerts
--
-- Additive only: new columns default to "off" / NULL, new tables start empty,
-- no existing row is changed. RLS stays on everywhere.
--
--  * notification_preferences.nearby_discovery  explicit opt-in (default false)
--  * donor_locations                            private donor coordinates
--  * blood_requests.latitude/longitude/label    request location
--  * nearby_donors / list_request_locations     shared by app and website;
--                                               approximate positions only
--  * app_settings                               admin-tunable alert settings
--  * emergency_alerts                           push queue + delivery log
--  * queue_emergency_alerts + trigger           matching when a request is
--                                               published (approved/active)
--  * register/unregister_push_token             Expo push tokens
--  * _claim_queued_alerts / _complete_alerts    used by the Edge Function
--                                               (service_role only)
--
-- Coordinates are plain numeric(9,6) + haversine (no PostGIS) so the local
-- PGlite test server runs this exact SQL. Cloud-only pieces (pg_net, Vault)
-- are detected at run time and skipped when absent.
-- ============================================================================

-- ── 1. Explicit opt-in for nearby discovery ─────────────────────────────────
alter table public.notification_preferences
  add column if not exists nearby_discovery boolean not null default false;
comment on column public.notification_preferences.nearby_discovery is
  'Explicit opt-in: donor appears on nearby maps (approximate position) and receives location-based emergency alerts. Default false.';

-- ── 2. Donor locations (private; never readable by other users) ─────────────
create table public.donor_locations (
  donor_id    uuid primary key references public.donors (id) on delete cascade,
  latitude    numeric(9,6) not null check (latitude between -90 and 90),
  longitude   numeric(9,6) not null check (longitude between -180 and 180),
  accuracy_m  integer check (accuracy_m is null or accuracy_m between 0 and 100000),
  source      text not null default 'gps' check (source in ('gps', 'manual')),
  updated_at  timestamptz not null default now()
);
create index donor_locations_lat_lng_idx on public.donor_locations (latitude, longitude);
alter table public.donor_locations enable row level security;
revoke all on public.donor_locations from anon, authenticated;
grant select, delete on public.donor_locations to authenticated;
create policy "donor locations: owner read" on public.donor_locations
  for select to authenticated using (donor_id = public.my_donor_id());
create policy "donor locations: owner delete" on public.donor_locations
  for delete to authenticated using (donor_id = public.my_donor_id());

-- ── 3. Request location ─────────────────────────────────────────────────────
alter table public.blood_requests
  add column if not exists latitude numeric(9,6) check (latitude is null or latitude between -90 and 90),
  add column if not exists longitude numeric(9,6) check (longitude is null or longitude between -180 and 180),
  add column if not exists location_label text check (location_label is null or char_length(location_label) <= 200);
alter table public.blood_requests
  add constraint blood_requests_location_pair check ((latitude is null) = (longitude is null));
create index blood_requests_lat_lng_idx on public.blood_requests (latitude, longitude) where latitude is not null;

-- ── 4. Admin-tunable alert settings (single row) ────────────────────────────
create table public.app_settings (
  id                            boolean primary key default true check (id),
  emergency_radius_km           integer not null default 10 check (emergency_radius_km between 1 and 100),
  escalation_radii_km           integer[] not null default '{25,50}',
  min_donors_before_escalation  integer not null default 5 check (min_donors_before_escalation between 0 and 1000),
  max_alerts_per_request        integer not null default 200 check (max_alerts_per_request between 1 and 2000),
  donor_cooldown_minutes        integer not null default 30 check (donor_cooldown_minutes between 0 and 1440),
  push_alerts_enabled           boolean not null default true,
  dispatch_url                  text check (dispatch_url is null or dispatch_url ~ '^https://[^ ]+$'),
  updated_by                    uuid references public.profiles (id) on delete set null,
  updated_at                    timestamptz not null default now(),
  constraint app_settings_escalation_valid check (
    cardinality(escalation_radii_km) <= 5
    and 1 <= all (escalation_radii_km) and 200 >= all (escalation_radii_km))
);
insert into public.app_settings (id) values (true) on conflict (id) do nothing;
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

-- ── 5. Emergency alert queue / delivery log ─────────────────────────────────
create table public.emergency_alerts (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.blood_requests (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  donor_id    uuid references public.donors (id) on delete set null,
  distance_km numeric(7,2),
  radius_km   integer,
  status      text not null default 'queued'
              check (status in ('queued', 'sending', 'sent', 'failed', 'skipped', 'no_device')),
  attempts    integer not null default 0,
  last_error  text check (last_error is null or char_length(last_error) <= 500),
  ticket_ids  text[],
  created_at  timestamptz not null default now(),
  claimed_at  timestamptz,
  sent_at     timestamptz,
  -- one alert per donor per request, whatever happens later
  constraint emergency_alerts_once_per_request unique (request_id, user_id)
);
create index emergency_alerts_status_idx on public.emergency_alerts (status, created_at);
create index emergency_alerts_user_sent_idx on public.emergency_alerts (user_id, sent_at desc) where status = 'sent';
alter table public.emergency_alerts enable row level security;
revoke all on public.emergency_alerts from anon, authenticated;
grant select on public.emergency_alerts to authenticated;
create policy "alerts: read own" on public.emergency_alerts
  for select to authenticated using (user_id = (select auth.uid()));

-- ── 6. Geo helper ───────────────────────────────────────────────────────────
create or replace function public._haversine_km(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns double precision language sql immutable set search_path = '' as $$
  select 6371.0 * 2 * asin(least(1.0, sqrt(
    power(sin(radians((lat2 - lat1)::float8) / 2), 2)
    + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lng2 - lng1)::float8) / 2), 2)
  )));
$$;

-- ── 7. Opt-in + my location ─────────────────────────────────────────────────
create or replace function public.set_nearby_discovery(_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
begin
  update public.notification_preferences
     set nearby_discovery = coalesce(_enabled, false), updated_at = now()
   where user_id = _uid;
  -- Turning discovery off removes the stored position immediately.
  if not coalesce(_enabled, false) then
    delete from public.donor_locations where donor_id = public.my_donor_id();
  end if;
end $$;

create or replace function public.set_my_location(_lat numeric, _lng numeric, _accuracy_m integer default null, _source text default 'gps')
returns void language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _donor uuid;
begin
  if not coalesce((select np.nearby_discovery from public.notification_preferences np where np.user_id = _uid), false) then
    perform public._fail('Turn on "Share Approximate Location" first.');
  end if;
  if (select p.account_type from public.profiles p where p.id = _uid) = 'recipient' then
    perform public._fail('Only donor accounts can share their location for nearby discovery.');
  end if;
  if _lat is null or _lng is null or _lat not between -90 and 90 or _lng not between -180 and 180 then
    perform public._fail('Invalid location.');
  end if;
  if coalesce(_source, 'gps') not in ('gps', 'manual') then perform public._fail('Invalid location source.'); end if;
  _donor := public._ensure_my_donor();
  insert into public.donor_locations (donor_id, latitude, longitude, accuracy_m, source, updated_at)
  values (_donor, round(_lat, 6), round(_lng, 6),
          case when _accuracy_m is null then null else greatest(0, least(_accuracy_m, 100000)) end,
          coalesce(_source, 'gps'), now())
  on conflict (donor_id) do update
    set latitude = excluded.latitude, longitude = excluded.longitude,
        accuracy_m = excluded.accuracy_m, source = excluded.source, updated_at = now();
end $$;

create or replace function public.clear_my_location()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_active_user();
  delete from public.donor_locations where donor_id = public.my_donor_id();
end $$;

-- ── 8. Nearby donors (app + website; approximate positions only) ────────────
-- Eligibility = search_donors' rules (active donor, active profile, show_in_search)
-- + nearby_discovery opt-in + a stored location. Positions are rounded to 2
-- decimals (~1.1 km) and the distance is computed from the rounded point, so
-- neither field reveals more than ~1 km. No phone or email.
create or replace function public.nearby_donors(
  _lat numeric, _lng numeric, _radius_km integer default 10, _blood_group text default null, _limit integer default 100)
returns table (
  id uuid, full_name text, blood_group text, city text, area text,
  availability public.availability_status, is_verified boolean, donations_count bigint,
  approx_lat numeric, approx_lng numeric, distance_km numeric)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  _r integer := case when _radius_km in (5, 10, 25, 50) then _radius_km else 10 end;
  _dlat double precision;
  _dlng double precision;
begin
  if _lat is null or _lng is null or _lat not between -90 and 90 or _lng not between -180 and 180 then
    perform public._fail('Invalid location.');
  end if;
  _dlat := (_r + 2) / 111.32;   -- +2 km margin covers the ~1 km rounding
  _dlng := (_r + 2) / greatest(0.01, 111.32 * cos(radians(_lat::float8)));
  return query
  with cand as (
    select d.id as did, coalesce(p.full_name, d.full_name)::text as dname, d.blood_group as dgroup,
           c.name::text as dcity, d.area as darea,
           coalesce(a.status, 'available'::public.availability_status) as davail,
           (d.is_verified or coalesce(p.is_verified, false)) as dverified,
           (select count(*) from public.donations x where x.donor_id = d.id) as ddonations,
           round(l.latitude, 2) as alat, round(l.longitude, 2) as alng
    from public.donor_locations l
    join public.donors d on d.id = l.donor_id
    join public.cities c on c.id = d.city_id
    join public.profiles p on p.id = d.profile_id
    join public.notification_preferences np on np.user_id = d.profile_id
    left join public.donor_availability a on a.donor_id = d.id
    where d.is_active and p.status = 'active' and np.nearby_discovery and np.show_in_search
      and l.latitude between _lat - _dlat and _lat + _dlat
      and l.longitude between _lng - _dlng and _lng + _dlng
      and (_blood_group is null or _blood_group = '' or d.blood_group = upper(_blood_group))
  ), measured as (
    select cand.*, round(public._haversine_km(_lat, _lng, cand.alat, cand.alng)::numeric, 1) as dist
    from cand
  )
  select m.did, m.dname, m.dgroup, m.dcity, m.darea, m.davail, m.dverified, m.ddonations, m.alat, m.alng, m.dist
  from measured m
  where m.dist <= _r
  order by m.dist, m.dname
  limit least(greatest(coalesce(_limit, 100), 1), 200);
end $$;

-- ── 9. Request locations for maps (published requests only, no contact) ─────
create or replace function public.list_request_locations(
  _lat numeric default null, _lng numeric default null, _radius_km integer default null, _limit integer default 100)
returns table (
  id uuid, reference_code text, blood_group text, units smallint, urgency public.request_urgency,
  status public.request_status, hospital_name text, city text, location_label text,
  latitude numeric, longitude numeric, distance_km numeric, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select r.id, r.reference_code, r.blood_group, r.units, r.urgency, r.status, r.hospital_name, c.name::text,
         r.location_label, round(r.latitude, 3), round(r.longitude, 3),
         case when _lat is not null and _lng is not null
              then round(public._haversine_km(_lat, _lng, r.latitude, r.longitude)::numeric, 1) end,
         r.created_at
  from public.blood_requests r
  join public.cities c on c.id = r.city_id
  where r.status in ('approved', 'active') and r.latitude is not null
    and (_radius_km is null or _lat is null or _lng is null
         or public._haversine_km(_lat, _lng, r.latitude, r.longitude) <= _radius_km)
  order by case r.urgency when 'critical' then 0 when 'urgent' then 1 else 2 end, r.created_at desc
  limit least(greatest(coalesce(_limit, 100), 1), 300);
$$;

-- ── 10. Request submission and read model gain the location ─────────────────
-- Copied from 0005 with the location added (marked "location").
create or replace function public.submit_blood_request(p jsonb)
returns table (id uuid, reference_code text, status public.request_status)
language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := (select auth.uid());
  _verified boolean := false;
  _source public.request_source;
  _urgency public.request_urgency;
  _status public.request_status := 'pending';
  _patient text := public._clean(p->>'patient_name', 100);
  _group text := upper(public._clean(p->>'blood_group', 3));
  _units int;
  _hospital_id uuid;
  _hospital_name text := public._clean(p->>'hospital_name', 160);
  _address text := public._clean(p->>'hospital_address', 250);
  _city_id int;
  _contact_name text := public._clean(p->>'contact_name', 100);
  _contact_phone text := public._clean(p->>'contact_phone', 30);
  _description text := public._clean(p->>'description', 1000);
  _needed_by timestamptz;
  _row public.blood_requests;
  _lat numeric;
  _lng numeric;
  _loc_label text := public._clean(p->>'location_label', 200);
begin
  -- who / where from
  if _uid is null then
    _source := 'website';
  else
    perform public._require_active_user();
    select is_verified into _verified from public.profiles where profiles.id = _uid;
    _source := case p->>'source' when 'website' then 'website'::public.request_source else 'android'::public.request_source end;
  end if;

  -- validation (messages are shown to users as-is)
  if _patient is null or char_length(_patient) < 2 then perform public._fail('Patient name is required.'); end if;
  if _group is null or not exists (select 1 from public.blood_groups where code = _group) then
    perform public._fail('Select a valid blood group.');
  end if;
  begin
    _units := coalesce(nullif(p->>'units', '')::int, 1);
  exception when others then perform public._fail('Units must be a number between 1 and 10.');
  end;
  if _units not between 1 and 10 then perform public._fail('Units must be a number between 1 and 10.'); end if;
  if _contact_phone is null or not public._valid_phone(_contact_phone) then
    perform public._fail('Enter a valid contact number.');
  end if;

  _urgency := case
    when p->>'urgency' in ('critical','urgent','normal') then (p->>'urgency')::public.request_urgency
    when coalesce((p->>'urgent')::boolean, false) then 'urgent'
    else 'normal' end;

  if nullif(p->>'needed_by', '') is not null then
    begin _needed_by := (p->>'needed_by')::timestamptz;
    exception when others then perform public._fail('Invalid "needed by" date.'); end;
  end if;

  -- hospital: either a known hospital id or free text + city
  if nullif(p->>'hospital_id', '') is not null then
    begin _hospital_id := (p->>'hospital_id')::uuid;
    exception when others then perform public._fail('Invalid hospital.'); end;
    select h.name, h.city_id, coalesce(_address, h.address)
      into _hospital_name, _city_id, _address
      from public.hospitals h where h.id = _hospital_id and h.is_active;
    if not found then perform public._fail('Selected hospital was not found.', 'P0002'); end if;
  else
    if _hospital_name is null or char_length(_hospital_name) < 2 then perform public._fail('Hospital name is required.'); end if;
    if nullif(p->>'city_id', '') is not null then
      select c.id into _city_id from public.cities c where c.id = (p->>'city_id')::int;
    end if;
    if _city_id is null then
      if public._clean(p->>'city', 80) is null then perform public._fail('City is required.'); end if;
      begin _city_id := public.resolve_city(p->>'city');
      exception when others then perform public._fail('Enter a valid city name.'); end;
    end if;
  end if;

  -- location (optional): picked on a map / GPS, or inherited from a known hospital
  if nullif(p->>'latitude', '') is not null or nullif(p->>'longitude', '') is not null then
    begin
      _lat := round((p->>'latitude')::numeric, 6);
      _lng := round((p->>'longitude')::numeric, 6);
    exception when others then perform public._fail('Invalid location.'); end;
    if _lat is null or _lng is null or _lat not between -90 and 90 or _lng not between -180 and 180 then
      perform public._fail('Invalid location.');
    end if;
  elsif _hospital_id is not null then
    select h.latitude, h.longitude into _lat, _lng from public.hospitals h where h.id = _hospital_id;
  end if;

  -- rate limits
  if _uid is null then
    if (select count(*) from public.blood_requests r
        where r.requester_id is null and r.contact_phone = _contact_phone
          and r.created_at > now() - interval '1 hour') >= 3 then
      perform public._fail('Too many requests from this contact number. Please try again later.', '54000');
    end if;
    if (select count(*) from public.blood_requests r
        where r.requester_id is null and r.created_at > now() - interval '10 minutes') >= 60 then
      perform public._fail('The service is busy. Please try again in a few minutes.', '54000');
    end if;
  elsif (select count(*) from public.blood_requests r
         where r.requester_id = _uid and r.created_at > now() - interval '1 hour') >= 5 then
    perform public._fail('You have posted several requests recently. Please wait before posting another.', '54000');
  end if;

  if _uid is not null and _verified then _status := 'active'; end if;

  insert into public.blood_requests (
    patient_name, blood_group, units, urgency, status, source, hospital_id, hospital_name,
    hospital_address, city_id, contact_name, contact_phone, description, needed_by, requester_id,
    approved_at, latitude, longitude, location_label
  ) values (
    _patient, _group, _units, _urgency, _status, _source, _hospital_id, _hospital_name,
    _address, _city_id, coalesce(_contact_name, _patient), _contact_phone, _description, _needed_by, _uid,
    case when _status = 'active' then now() end, _lat, _lng, _loc_label
  ) returning * into _row;

  return query select _row.id, _row.reference_code, _row.status;
end $$;

-- Copied from 0007 with latitude / longitude / location_label added.
create or replace function public._request_json(r public.blood_requests, _with_contact boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'reference_code', r.reference_code, 'patient_name', r.patient_name,
    'blood_group', r.blood_group, 'units', r.units, 'urgency', r.urgency, 'status', r.status,
    'source', r.source, 'hospital_id', r.hospital_id, 'hospital_name', r.hospital_name,
    'hospital_address', r.hospital_address, 'city', (select c.name from public.cities c where c.id = r.city_id),
    'city_id', r.city_id, 'description', r.description, 'needed_by', r.needed_by,
    'contact_name', case when _with_contact then r.contact_name end,
    'contact_phone', case when _with_contact then r.contact_phone end,
    'status_reason', r.status_reason, 'created_at', r.created_at, 'updated_at', r.updated_at,
    'approved_at', r.approved_at, 'fulfilled_at', r.fulfilled_at,
    'latitude', r.latitude, 'longitude', r.longitude, 'location_label', r.location_label,
    'responded_count', (select count(*) from public.request_responses rr
                         where rr.request_id = r.id and rr.status <> 'withdrawn'),
    'is_mine', coalesce(r.requester_id = (select auth.uid()), false),
    'my_response', (select rr.status from public.request_responses rr
                     where rr.request_id = r.id and rr.responder_id = (select auth.uid()))
  );
$$;

-- ── 11. Push tokens ─────────────────────────────────────────────────────────
create or replace function public.register_push_token(_token text, _platform text default 'android')
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
begin
  if _token is null or _token !~ '^Expo(nent)?PushToken\[[A-Za-z0-9_-]{10,200}\]$' then
    perform public._fail('Invalid push token.');
  end if;
  if coalesce(_platform, '') not in ('android', 'ios', 'web') then perform public._fail('Invalid platform.'); end if;
  -- A token belongs to one device; if another account used it before, it moves here.
  insert into public.device_push_tokens (token, user_id, platform, created_at, last_seen)
  values (_token, _uid, _platform, now(), now())
  on conflict (token) do update
    set user_id = excluded.user_id, platform = excluded.platform, last_seen = now();
end $$;

create or replace function public.unregister_push_token(_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_active_user();
  delete from public.device_push_tokens where token = _token and user_id = (select auth.uid());
end $$;

-- ── 12. Matching: who should be alerted for a published request ─────────────
-- Same eligibility as the in-app fan-out in on_blood_request_status (compatible,
-- available, active donor + profile, push_enabled, emergency_alerts unless the
-- request is normal urgency, not the requester), plus location:
--   request with coordinates → donors opted in to nearby discovery with a
--                              stored location within _radius_km
--   request without          → donors in the same city (previous behaviour)
create or replace function public._emergency_candidates(_request_id uuid, _radius_km integer)
returns table (user_id uuid, donor_id uuid, distance_km numeric)
language sql stable security definer set search_path = '' as $$
  select d.profile_id, d.id,
         case when r.latitude is not null
              then round(public._haversine_km(r.latitude, r.longitude, l.latitude, l.longitude)::numeric, 2) end
  from public.blood_requests r
  join public.donors d on d.is_active and d.profile_id is not null and d.profile_id is distinct from r.requester_id
  join public.blood_groups bg on bg.code = d.blood_group and r.blood_group = any (bg.can_donate_to)
  join public.profiles p on p.id = d.profile_id and p.status = 'active'
  join public.notification_preferences np on np.user_id = d.profile_id and np.push_enabled
       and (np.emergency_alerts or r.urgency = 'normal')
  left join public.donor_availability a on a.donor_id = d.id
  left join public.donor_locations l on l.donor_id = d.id
  where r.id = _request_id
    and coalesce(a.status, 'available'::public.availability_status) = 'available'
    and case
          when r.latitude is not null then
            np.nearby_discovery and l.donor_id is not null
            and l.latitude between r.latitude - (_radius_km / 111.32) and r.latitude + (_radius_km / 111.32)
            and public._haversine_km(r.latitude, r.longitude, l.latitude, l.longitude) <= _radius_km
          else d.city_id = r.city_id
        end;
$$;

create or replace function public.queue_emergency_alerts(_request_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  _s public.app_settings;
  _r public.blood_requests;
  _radius integer;
  _radii integer[];
  _count integer := 0;
  _queued integer := 0;
begin
  select * into _s from public.app_settings where id;
  if not found or not _s.push_alerts_enabled then return 0; end if;
  select * into _r from public.blood_requests where id = _request_id;
  if not found or _r.status not in ('approved', 'active') then return 0; end if;

  if _r.latitude is not null then
    -- start at the default radius; widen until enough donors are found
    _radii := array[_s.emergency_radius_km]
              || array(select x from unnest(coalesce(_s.escalation_radii_km, '{}')) x
                       where x > _s.emergency_radius_km order by x);
    foreach _radius in array _radii loop
      select count(*) into _count from public._emergency_candidates(_request_id, _radius);
      exit when _count >= _s.min_donors_before_escalation;
    end loop;
  else
    _radius := null;
  end if;

  insert into public.emergency_alerts (request_id, user_id, donor_id, distance_km, radius_km, status, last_error)
  select _request_id, c.user_id, c.donor_id, c.distance_km, _radius,
         case
           when exists (select 1 from public.emergency_alerts e
                        where e.user_id = c.user_id and e.status = 'sent'
                          and e.sent_at > now() - make_interval(mins => _s.donor_cooldown_minutes)) then 'skipped'
           when not exists (select 1 from public.device_push_tokens t where t.user_id = c.user_id) then 'no_device'
           else 'queued'
         end,
         case
           when exists (select 1 from public.emergency_alerts e
                        where e.user_id = c.user_id and e.status = 'sent'
                          and e.sent_at > now() - make_interval(mins => _s.donor_cooldown_minutes)) then 'cooldown'
           when not exists (select 1 from public.device_push_tokens t where t.user_id = c.user_id) then 'no registered device'
         end
  from public._emergency_candidates(_request_id, coalesce(_radius, 0)) c
  order by c.distance_km nulls last
  limit _s.max_alerts_per_request
  on conflict (request_id, user_id) do nothing;
  get diagnostics _queued = row_count;
  return _queued;
end $$;

-- ── 13. Dispatch (cloud: pg_net → Edge Function; locally a no-op) ───────────
create or replace function public._alert_dispatch_secret()
returns text language plpgsql stable security definer set search_path = '' as $$
declare _s text;
begin
  if to_regclass('vault.decrypted_secrets') is null then return null; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
    into _s using 'lifelink_alert_dispatch_secret';
  return _s;
end $$;

create or replace function public._kick_alert_dispatch(_request_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  _url text;
  _secret text;
begin
  select s.dispatch_url into _url from public.app_settings s where s.id and s.push_alerts_enabled;
  if _url is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then return; end if;
  if not exists (select 1 from public.emergency_alerts e
                 where e.status = 'queued' and (_request_id is null or e.request_id = _request_id)) then
    return;
  end if;
  _secret := public._alert_dispatch_secret();
  if _secret is null then return; end if;
  execute 'select net.http_post(url := $1, body := $2, params := ''{}''::jsonb, headers := $3, timeout_milliseconds := 5000)'
    using _url, jsonb_build_object('request_id', _request_id),
          jsonb_build_object('Content-Type', 'application/json', 'x-dispatch-secret', _secret);
exception when others then
  raise warning 'LifeLink alert dispatch kick failed: %', sqlerrm;
end $$;

-- Generate the shared dispatch secret in Vault (cloud only; skipped locally).
do $$
begin
  if to_regclass('vault.secrets') is not null then
    execute $v$
      select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
                                 'lifelink_alert_dispatch_secret',
                                 'Shared secret between pg_net and the send-emergency-alerts Edge Function')
      where not exists (select 1 from vault.secrets where name = 'lifelink_alert_dispatch_secret')
    $v$;
  end if;
end $$;

-- ── 14. Trigger: queue + dispatch when a request is first published ─────────
create or replace function public.on_blood_request_published()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('approved', 'active')
     and (tg_op = 'INSERT' or old.status not in ('approved', 'active')) then
    -- Alerts must never block approving / posting a request.
    begin
      perform public.queue_emergency_alerts(new.id);
      perform public._kick_alert_dispatch(new.id);
    exception when others then
      raise warning 'LifeLink emergency alert queueing failed for %: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end $$;

create trigger blood_requests_emergency_alerts
  after insert or update of status on public.blood_requests
  for each row execute function public.on_blood_request_published();

-- ── 15. Edge Function helpers (service_role only) ───────────────────────────
create or replace function public._claim_queued_alerts(_request_id uuid default null, _limit integer default 500)
returns table (
  alert_id bigint, user_id uuid, tokens text[], request_id uuid, blood_group text, units smallint,
  urgency public.request_urgency, hospital_name text, city text, distance_km numeric)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  return query
  with picked as (
    select e.id from public.emergency_alerts e
    where (e.status = 'queued'
           or (e.status = 'sending' and e.claimed_at < now() - interval '10 minutes' and e.attempts < 3))
      and (_request_id is null or e.request_id = _request_id)
    order by e.created_at
    limit least(greatest(coalesce(_limit, 500), 1), 1000)
    for update skip locked
  ), upd as (
    update public.emergency_alerts e
       set status = 'sending', attempts = e.attempts + 1, claimed_at = now()
      from picked
     where e.id = picked.id
    returning e.id as aid, e.user_id as auid, e.request_id as arid, e.distance_km as adist
  )
  select u.aid, u.auid,
         array(select t.token from public.device_push_tokens t where t.user_id = u.auid order by t.last_seen desc limit 5),
         r.id, r.blood_group, r.units, r.urgency, r.hospital_name, c.name::text, u.adist
  from upd u
  join public.blood_requests r on r.id = u.arid
  join public.cities c on c.id = r.city_id;
end $$;

create or replace function public._complete_alerts(_results jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare _n integer;
begin
  update public.emergency_alerts e set
    status     = case when x.status in ('sent', 'failed', 'no_device') then x.status else 'failed' end,
    last_error = left(x.error, 500),
    ticket_ids = x.ticket_ids,
    sent_at    = case when x.status = 'sent' then now() end
  from jsonb_to_recordset(coalesce(_results, '[]'::jsonb)) as x(alert_id bigint, status text, error text, ticket_ids text[])
  where e.id = x.alert_id and e.status = 'sending';
  get diagnostics _n = row_count;
  -- Expo reported these tokens as no longer registered: forget them.
  delete from public.device_push_tokens t
  where t.token in (select jsonb_array_elements_text(r.value -> 'invalid_tokens')
                    from jsonb_array_elements(coalesce(_results, '[]'::jsonb)) r
                    where jsonb_typeof(r.value -> 'invalid_tokens') = 'array');
  return _n;
end $$;

-- ── 16. Admin API ───────────────────────────────────────────────────────────
create or replace function public.admin_get_alert_settings()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._require_staff();
  return (select to_jsonb(s) - 'id' || jsonb_build_object(
            'dispatch_ready', s.dispatch_url is not null
                              and to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null)
          from public.app_settings s where s.id);
end $$;

create or replace function public.admin_update_alert_settings(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_admin();
  _radii integer[];
begin
  if p ? 'escalation_radii_km' then
    begin
      _radii := array(select (x)::int from jsonb_array_elements_text(p->'escalation_radii_km') x order by 1);
    exception when others then perform public._fail('Escalation radii must be whole numbers of km.'); end;
  end if;
  begin
    update public.app_settings s set
      emergency_radius_km          = coalesce((p->>'emergency_radius_km')::int, s.emergency_radius_km),
      escalation_radii_km          = coalesce(_radii, s.escalation_radii_km),
      min_donors_before_escalation = coalesce((p->>'min_donors_before_escalation')::int, s.min_donors_before_escalation),
      max_alerts_per_request       = coalesce((p->>'max_alerts_per_request')::int, s.max_alerts_per_request),
      donor_cooldown_minutes       = coalesce((p->>'donor_cooldown_minutes')::int, s.donor_cooldown_minutes),
      push_alerts_enabled          = coalesce((p->>'push_alerts_enabled')::boolean, s.push_alerts_enabled),
      dispatch_url                 = case when p ? 'dispatch_url' then nullif(trim(p->>'dispatch_url'), '') else s.dispatch_url end,
      updated_by = _uid, updated_at = now()
    where s.id;
  exception
    when check_violation then perform public._fail('A setting is outside its allowed range (radius 1–100 km, escalation 1–200 km, cooldown 0–1440 min, max alerts 1–2000).');
    when invalid_text_representation then perform public._fail('Settings must be numbers (and true/false for on/off).');
  end;
  perform public._log_admin('alerts.settings', 'app_settings', 'singleton', p - 'dispatch_url');
  return public.admin_get_alert_settings();
end $$;

create or replace function public.admin_alert_stats(_days integer default 7)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _since timestamptz := now() - make_interval(days => least(greatest(coalesce(_days, 7), 1), 90));
begin
  perform public._require_staff();
  return jsonb_build_object(
    'days', least(greatest(coalesce(_days, 7), 1), 90),
    'by_status', coalesce((select jsonb_object_agg(status, n) from (
        select e.status, count(*) n from public.emergency_alerts e where e.created_at >= _since group by e.status) s), '{}'::jsonb),
    'requests_alerted', (select count(distinct e.request_id) from public.emergency_alerts e where e.created_at >= _since),
    'devices', (select count(*) from public.device_push_tokens),
    'donors_sharing_location', (select count(*) from public.donor_locations),
    'last_sent_at', (select max(e.sent_at) from public.emergency_alerts e));
end $$;

create or replace function public.admin_list_alert_failures(_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', e.id, 'reference_code', r.reference_code, 'hospital_name', r.hospital_name,
             'status', e.status, 'error', e.last_error, 'attempts', e.attempts,
             'created_at', e.created_at) order by e.created_at desc)
    from (select * from public.emergency_alerts
          where status in ('failed', 'no_device') order by created_at desc
          limit least(greatest(coalesce(_limit, 50), 1), 200)) e
    join public.blood_requests r on r.id = e.request_id), '[]'::jsonb);
end $$;

create or replace function public.admin_list_live_requests_with_alerts()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', r.id, 'reference_code', r.reference_code, 'blood_group', r.blood_group, 'units', r.units,
             'urgency', r.urgency, 'status', r.status, 'hospital_name', r.hospital_name,
             'city', (select c.name from public.cities c where c.id = r.city_id),
             'has_location', r.latitude is not null, 'created_at', r.created_at,
             'alerts', coalesce((select jsonb_object_agg(x.status, x.n) from (
                         select e.status, count(*) n from public.emergency_alerts e
                         where e.request_id = r.id group by e.status) x), '{}'::jsonb))
           order by case r.urgency when 'critical' then 0 when 'urgent' then 1 else 2 end, r.created_at desc)
    from public.blood_requests r where r.status in ('approved', 'active')), '[]'::jsonb);
end $$;

-- ── 17. Privileges (explicit allow-list; see migration 0007 for why) ────────
revoke execute on function
  public._haversine_km(numeric, numeric, numeric, numeric),
  public.set_nearby_discovery(boolean),
  public.set_my_location(numeric, numeric, integer, text),
  public.clear_my_location(),
  public.nearby_donors(numeric, numeric, integer, text, integer),
  public.list_request_locations(numeric, numeric, integer, integer),
  public.register_push_token(text, text),
  public.unregister_push_token(text),
  public._emergency_candidates(uuid, integer),
  public.queue_emergency_alerts(uuid),
  public._alert_dispatch_secret(),
  public._kick_alert_dispatch(uuid),
  public.on_blood_request_published(),
  public._claim_queued_alerts(uuid, integer),
  public._complete_alerts(jsonb),
  public.admin_get_alert_settings(),
  public.admin_update_alert_settings(jsonb),
  public.admin_alert_stats(integer),
  public.admin_list_alert_failures(integer),
  public.admin_list_live_requests_with_alerts(),
  public._request_json(public.blood_requests, boolean),
  public.submit_blood_request(jsonb)
from public, anon, authenticated;

grant execute on function
  public.nearby_donors(numeric, numeric, integer, text, integer),
  public.list_request_locations(numeric, numeric, integer, integer),
  public.submit_blood_request(jsonb)
to anon, authenticated;

grant execute on function
  public.set_nearby_discovery(boolean),
  public.set_my_location(numeric, numeric, integer, text),
  public.clear_my_location(),
  public.register_push_token(text, text),
  public.unregister_push_token(text),
  public.admin_get_alert_settings(),
  public.admin_update_alert_settings(jsonb),
  public.admin_alert_stats(integer),
  public.admin_list_alert_failures(integer),
  public.admin_list_live_requests_with_alerts()
to authenticated;

grant execute on function
  public._claim_queued_alerts(uuid, integer),
  public._complete_alerts(jsonb),
  public._alert_dispatch_secret()
to service_role;

-- ── 18. Hospitals: coordinates can be set when editing ──────────────────────
-- Copied from 0007; the update branch now also saves latitude / longitude
-- (previously only a newly created hospital could get coordinates).
create or replace function public.admin_upsert_hospital(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _id uuid := nullif(p->>'id', '')::uuid;
  _name text := public._clean(p->>'name', 160);
  _type text := coalesce(public._clean(p->>'type', 20), 'private');
  _addr text := public._clean(p->>'address', 250);
  _phone text := public._clean(p->>'phone', 30);
  _city integer;
begin
  if _id is null and not public.is_admin() then perform public._fail('Admin access required.', '42501'); end if;
  if _id is not null and not public.manages_hospital(_id) then perform public._fail('Not allowed to edit this hospital.', '42501'); end if;
  if _name is null or char_length(_name) < 3 then perform public._fail('Hospital name is required.'); end if;
  if _type not in ('private', 'public', 'semi_government') then perform public._fail('Invalid hospital type.'); end if;
  if _addr is null or char_length(_addr) < 5 then perform public._fail('Address is required.'); end if;
  if _phone is not null and not public._valid_phone(_phone) then perform public._fail('Please enter a valid phone number.'); end if;
  _city := public.resolve_city(coalesce(p->>'city', ''));

  if _id is null then
    insert into public.hospitals (name, type, has_blood_bank, city_id, address, phone, email, open_24h,
                                  opening_hours, beds, about, services, is_verified, is_active, latitude, longitude)
    values (_name, _type::public.hospital_type, coalesce((p->>'has_blood_bank')::boolean, false), _city, _addr, _phone,
            nullif(public._clean(p->>'email', 120), ''), coalesce((p->>'open_24h')::boolean, true),
            public._clean(p->>'opening_hours', 80), nullif(p->>'beds', '')::int, public._clean(p->>'about', 1000),
            coalesce((select array_agg(public._clean(s, 60)) from jsonb_array_elements_text(coalesce(p->'services', '[]')) s
                      where public._clean(s, 60) is not null), '{}'),
            coalesce((p->>'is_verified')::boolean, false), coalesce((p->>'is_active')::boolean, true),
            nullif(p->>'latitude', '')::numeric, nullif(p->>'longitude', '')::numeric)
    returning id into _id;
    insert into public.hospital_inventory (hospital_id, blood_group, units)
    select _id, code, 0 from public.blood_groups on conflict do nothing;
    perform public._log_admin('hospital.create', 'hospital', _id::text, jsonb_build_object('name', _name));
  else
    update public.hospitals set
      name = _name, type = _type::public.hospital_type,
      has_blood_bank = coalesce((p->>'has_blood_bank')::boolean, has_blood_bank),
      city_id = _city, address = _addr, phone = _phone,
      email = case when p ? 'email' then nullif(public._clean(p->>'email', 120), '') else email end,
      open_24h = coalesce((p->>'open_24h')::boolean, open_24h),
      opening_hours = case when p ? 'opening_hours' then public._clean(p->>'opening_hours', 80) else opening_hours end,
      beds = case when p ? 'beds' then nullif(p->>'beds', '')::int else beds end,
      about = case when p ? 'about' then public._clean(p->>'about', 1000) else about end,
      services = case when p ? 'services' then coalesce((select array_agg(public._clean(s, 60))
                   from jsonb_array_elements_text(p->'services') s where public._clean(s, 60) is not null), '{}') else services end,
      latitude  = case when p ? 'latitude'  then nullif(p->>'latitude', '')::numeric  else latitude end,
      longitude = case when p ? 'longitude' then nullif(p->>'longitude', '')::numeric else longitude end,
      is_verified = case when public.is_admin() then coalesce((p->>'is_verified')::boolean, is_verified) else is_verified end,
      is_active   = case when public.is_admin() then coalesce((p->>'is_active')::boolean, is_active) else is_active end
    where id = _id;
    if not found then perform public._fail('Hospital not found.', 'P0002'); end if;
    perform public._log_admin('hospital.update', 'hospital', _id::text, jsonb_build_object('name', _name));
  end if;
  return _id;
end $$;

revoke execute on function public.admin_upsert_hospital(jsonb) from public, anon;
grant execute on function public.admin_upsert_hospital(jsonb) to authenticated;
