-- ============================================================================
-- LifeLink Platform — 0005: RPC functions (single source of business rules)
--
-- Every client (website, Android app, admin dashboard) calls these through
-- supabase.rpc(...). Validation, rate limits, status transitions and role
-- checks live HERE, never only in a client.
-- Errors are raised with SQLSTATE 22023 (bad input), 42501 (not allowed),
-- P0002 (not found) or 54000 (rate limited) and a human-readable message.
-- ============================================================================

-- ── Internal helpers ─────────────────────────────────────────────────────────
create or replace function public._fail(_msg text, _code text default '22023')
returns void language plpgsql set search_path = '' as $$
begin
  raise exception '%', _msg using errcode = _code;
end $$;

create or replace function public._clean(_v text, _max int)
returns text language sql immutable set search_path = '' as $$
  select nullif(left(regexp_replace(trim(coalesce(_v, '')), '\s+', ' ', 'g'), _max), '');
$$;

create or replace function public._valid_phone(_v text)
returns boolean language sql immutable set search_path = '' as $$
  select _v ~ '^\+?[0-9][0-9 ()\-]{6,22}$';
$$;

create or replace function public._valid_email(_v text)
returns boolean language sql immutable set search_path = '' as $$
  select _v ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' and char_length(_v) <= 254;
$$;

create or replace function public._log_admin(_action text, _target_type text, _target_id text, _details jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into public.admin_activity_logs (admin_id, action, target_type, target_id, details)
  values ((select auth.uid()), _action, _target_type, _target_id, coalesce(_details, '{}'));
$$;

create or replace function public._require_active_user()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare _uid uuid := (select auth.uid());
begin
  if _uid is null then perform public._fail('Please sign in to continue.', '42501'); end if;
  if not exists (select 1 from public.profiles where id = _uid and status = 'active') then
    perform public._fail('Your account is suspended. Contact support.', '42501');
  end if;
  return _uid;
end $$;

create or replace function public._require_staff()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
begin
  if not public.is_staff() then perform public._fail('Admin access required.', '42501'); end if;
  return _uid;
end $$;

create or replace function public._require_admin()
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
begin
  if not public.is_admin() then perform public._fail('Admin access required.', '42501'); end if;
  return _uid;
end $$;

-- Ensure the signed-in user has a donor row; create it from the profile if possible.
create or replace function public._ensure_my_donor()
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _p public.profiles;
  _id uuid;
begin
  select id into _id from public.donors where profile_id = _uid;
  if _id is not null then return _id; end if;
  select * into _p from public.profiles where id = _uid;
  if _p.blood_group is null or _p.city_id is null then
    perform public._fail('Add your blood group and city to your profile first.');
  end if;
  insert into public.donors (profile_id, blood_group, city_id, area)
  values (_uid, _p.blood_group, _p.city_id, _p.area) returning id into _id;
  insert into public.donor_availability (donor_id, updated_by) values (_id, _uid);
  return _id;
end $$;

-- Keep a linked donor's blood group / city / area in sync with the profile.
create or replace function public.sync_profile_to_donor()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.donors d set
    blood_group = coalesce(new.blood_group, d.blood_group),
    city_id     = coalesce(new.city_id, d.city_id),
    area        = new.area
  where d.profile_id = new.id
    and (new.blood_group is distinct from old.blood_group
      or new.city_id is distinct from old.city_id
      or new.area is distinct from old.area);
  return new;
end $$;

create trigger profiles_sync_donor after update on public.profiles
  for each row execute function public.sync_profile_to_donor();

-- ============================================================================
-- PUBLIC (anon + authenticated)
-- ============================================================================

-- Create a blood request from the website or the app.
--   anonymous  → source 'website', status 'pending' (admin review), rate limited
--   signed in  → requester_id set; verified accounts go live ('active') immediately
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
    approved_at
  ) values (
    _patient, _group, _units, _urgency, _status, _source, _hospital_id, _hospital_name,
    _address, _city_id, coalesce(_contact_name, _patient), _contact_phone, _description, _needed_by, _uid,
    case when _status = 'active' then now() end
  ) returning * into _row;

  return query select _row.id, _row.reference_code, _row.status;
end $$;

-- Website "Become a Donor" application (anonymous allowed).
create or replace function public.submit_donor_application(p jsonb)
returns table (id uuid, status public.application_status)
language plpgsql security definer set search_path = '' as $$
declare
  _name text := public._clean(p->>'full_name', 100);
  _email text := lower(public._clean(p->>'email', 254));
  _phone text := public._clean(p->>'phone', 30);
  _age int;
  _gender text := lower(public._clean(p->>'gender', 10));
  _group text := upper(public._clean(p->>'blood_group', 3));
  _city int;
  _row public.donor_applications;
begin
  if (select auth.uid()) is not null then perform public._require_active_user(); end if;
  if _name is null or char_length(_name) < 2 then perform public._fail('Full name is required.'); end if;
  if _email is null or not public._valid_email(_email) then perform public._fail('Enter a valid email address.'); end if;
  if _phone is null or not public._valid_phone(_phone) then perform public._fail('Enter a valid phone number.'); end if;
  begin _age := (p->>'age')::int; exception when others then _age := null; end;
  if _age is null or _age not between 17 and 65 then perform public._fail('Donors must be between 17 and 65 years old.'); end if;
  if _gender not in ('male','female','other') then perform public._fail('Select a gender.'); end if;
  if _group is null or not exists (select 1 from public.blood_groups where code = _group) then
    perform public._fail('Select a valid blood group.');
  end if;
  begin _city := public.resolve_city(p->>'city');
  exception when others then perform public._fail('Enter a valid city name.'); end;

  if exists (select 1 from public.donor_applications a where a.email = _email and a.status = 'pending') then
    perform public._fail('A pending request with this email already exists.');
  end if;
  if exists (select 1 from public.donors d where d.email = _email)
     or exists (select 1 from public.donors d join public.profiles pr on pr.id = d.profile_id where pr.email = _email) then
    perform public._fail('This email is already registered as a donor.');
  end if;
  if (select count(*) from public.donor_applications a where a.created_at > now() - interval '10 minutes') >= 60 then
    perform public._fail('The service is busy. Please try again in a few minutes.', '54000');
  end if;

  insert into public.donor_applications (full_name, email, phone, age, gender, blood_group, city_id, submitted_by,
                                         source)
  values (_name, _email, _phone, _age, _gender::public.gender, _group, _city, (select auth.uid()),
          case when p->>'source' = 'android' then 'android'::public.request_source else 'website'::public.request_source end)
  returning * into _row;

  return query select _row.id, _row.status;
end $$;

-- Website "Contact Us" form.
create or replace function public.submit_contact_message(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  _first text := public._clean(p->>'first_name', 100);
  _email text := lower(public._clean(p->>'email', 254));
  _phone text := public._clean(p->>'phone', 30);
  _msg text := left(trim(coalesce(p->>'message', '')), 4000);
  _id uuid;
begin
  if _first is null then perform public._fail('First name is required.'); end if;
  if _email is null or not public._valid_email(_email) then perform public._fail('Enter a valid email address.'); end if;
  if _phone is not null and not public._valid_phone(_phone) then perform public._fail('Enter a valid phone number.'); end if;
  if char_length(_msg) < 5 then perform public._fail('Please write a message.'); end if;
  if (select count(*) from public.contact_messages m where m.email = _email and m.created_at > now() - interval '1 hour') >= 5 then
    perform public._fail('Too many messages. Please try again later.', '54000');
  end if;
  insert into public.contact_messages (first_name, last_name, email, phone, message)
  values (_first, public._clean(p->>'last_name', 100), _email, _phone, _msg)
  returning contact_messages.id into _id;
  return _id;
end $$;

-- Donor discovery WITHOUT contact details (website search page + app Donors tab).
create or replace function public.search_donors(
  _blood_group text default null,
  _city text default null,
  _query text default null,
  _available_only boolean default false,
  _sort text default 'donations',          -- donations | rating | recent
  _limit int default 20,
  _offset int default 0
) returns table (
  id uuid, full_name text, blood_group text, city text, area text,
  availability public.availability_status, donations_count bigint, rating numeric,
  rating_count int, is_verified boolean, hours text, last_donation_on date, total_count bigint
)
language sql stable security definer set search_path = '' as $$
  with base as (
    select d.id,
           coalesce(p.full_name, d.full_name)::text as full_name,
           d.blood_group, c.name as city, d.area,
           coalesce(a.status, 'available'::public.availability_status) as availability,
           (select count(*) from public.donations x where x.donor_id = d.id) as donations_count,
           d.rating, d.rating_count,
           (d.is_verified or coalesce(p.is_verified, false)) as is_verified,
           d.hours,
           (select max(x.donated_on) from public.donations x where x.donor_id = d.id) as last_donation_on,
           d.created_at
    from public.donors d
    join public.cities c on c.id = d.city_id
    left join public.profiles p on p.id = d.profile_id
    left join public.donor_availability a on a.donor_id = d.id
    left join public.notification_preferences np on np.user_id = d.profile_id
    where d.is_active
      and (p.id is null or p.status = 'active')
      and coalesce(np.show_in_search, true)
      and (_blood_group is null or _blood_group = '' or d.blood_group = upper(_blood_group))
      and (_city is null or trim(_city) = '' or c.name_key like '%' || lower(trim(_city)) || '%')
      and (_query is null or trim(_query) = ''
           or coalesce(p.full_name, d.full_name)::text ilike '%' || trim(_query) || '%'
           or c.name ilike '%' || trim(_query) || '%'
           or d.area ilike '%' || trim(_query) || '%')
  )
  select b.id, b.full_name, b.blood_group, b.city, b.area, b.availability, b.donations_count,
         b.rating, b.rating_count, b.is_verified, b.hours, b.last_donation_on,
         count(*) over () as total_count
  from base b
  where not _available_only or b.availability = 'available'
  order by
    case when _sort = 'rating' then b.rating end desc nulls last,
    case when _sort = 'recent' then b.created_at end desc,
    b.donations_count desc, b.full_name
  limit least(greatest(coalesce(_limit, 20), 1), 100)
  offset greatest(coalesce(_offset, 0), 0);
$$;

-- Public donor profile (no contact details).
create or replace function public.get_donor_public(_donor_id uuid)
returns table (
  id uuid, full_name text, blood_group text, city text, area text, gender public.gender,
  availability public.availability_status, donations_count bigint, rating numeric, rating_count int,
  is_verified boolean, hours text, about text, last_donation_on date, member_since timestamptz
)
language sql stable security definer set search_path = '' as $$
  select d.id, coalesce(p.full_name, d.full_name)::text, d.blood_group, c.name, d.area,
         coalesce(p.gender, d.gender),
         coalesce(a.status, 'available'),
         (select count(*) from public.donations x where x.donor_id = d.id),
         d.rating, d.rating_count, (d.is_verified or coalesce(p.is_verified, false)), d.hours, d.about,
         (select max(x.donated_on) from public.donations x where x.donor_id = d.id),
         coalesce(p.created_at, d.created_at)
  from public.donors d
  join public.cities c on c.id = d.city_id
  left join public.profiles p on p.id = d.profile_id
  left join public.donor_availability a on a.donor_id = d.id
  where d.id = _donor_id and d.is_active and (p.id is null or p.status = 'active');
$$;

-- Reveal a donor's phone number to a signed-in, active user (logged).
create or replace function public.get_donor_contact(_donor_id uuid)
returns table (full_name text, phone text)
language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
begin
  if (select count(*) from public.audit_logs l
      where l.table_name = 'contact_reveal' and l.actor_id = _uid and l.created_at > now() - interval '1 hour') >= 30 then
    perform public._fail('Contact limit reached. Please try again later.', '54000');
  end if;
  insert into public.audit_logs (table_name, record_id, action, actor_id)
  values ('contact_reveal', _donor_id::text, 'INSERT', _uid);
  return query
    select coalesce(p.full_name, d.full_name)::text, coalesce(p.phone, d.phone)::text
    from public.donors d left join public.profiles p on p.id = d.profile_id
    where d.id = _donor_id and d.is_active;
end $$;

-- Published requests without contact details (anonymous-safe listing).
create or replace function public.list_public_requests(
  _blood_group text default null, _city text default null,
  _urgent_only boolean default false, _include_fulfilled boolean default false,
  _limit int default 20, _offset int default 0
) returns table (
  id uuid, reference_code text, patient_name text, blood_group text, units smallint,
  urgency public.request_urgency, status public.request_status, hospital_name text, city text,
  description text, responded_count bigint, created_at timestamptz, total_count bigint
)
language sql stable security definer set search_path = '' as $$
  select r.id, r.reference_code, r.patient_name::text, r.blood_group, r.units, r.urgency, r.status,
         r.hospital_name, c.name, r.description,
         (select count(*) from public.request_responses x where x.request_id = r.id and x.status <> 'withdrawn'),
         r.created_at, count(*) over ()
  from public.blood_requests r join public.cities c on c.id = r.city_id
  where (r.status in ('approved','active') or (_include_fulfilled and r.status = 'fulfilled'))
    and (_blood_group is null or _blood_group = '' or r.blood_group = upper(_blood_group))
    and (_city is null or trim(_city) = '' or c.name_key like '%' || lower(trim(_city)) || '%')
    and (not _urgent_only or r.urgency <> 'normal')
  order by case r.urgency when 'critical' then 0 when 'urgent' then 1 else 2 end, r.created_at desc
  limit least(greatest(coalesce(_limit, 20), 1), 100)
  offset greatest(coalesce(_offset, 0), 0);
$$;

-- Public platform totals (homepage could use these later; read-only).
create or replace function public.public_stats()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'donors',          (select count(*) from public.donors where is_active),
    'available_donors',(select count(*) from public.donor_availability where status = 'available'),
    'hospitals',       (select count(*) from public.hospitals where is_active),
    'cities',          (select count(distinct city_id) from public.donors where is_active),
    'lives_saved',     (select coalesce(sum(units), 0) * 3 from public.donations),
    'open_requests',   (select count(*) from public.blood_requests where status in ('approved','active'))
  );
$$;

-- ============================================================================
-- SIGNED-IN USERS
-- ============================================================================

create or replace function public.register_as_donor(_blood_group text default null, _city text default null, _area text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
begin
  if _blood_group is not null then
    if not exists (select 1 from public.blood_groups where code = upper(_blood_group)) then
      perform public._fail('Select a valid blood group.');
    end if;
    update public.profiles set blood_group = upper(_blood_group) where id = _uid;
  end if;
  if public._clean(_city, 80) is not null then
    update public.profiles set city_id = public.resolve_city(_city) where id = _uid;
  end if;
  if _area is not null then update public.profiles set area = public._clean(_area, 120) where id = _uid; end if;
  update public.profiles set account_type = 'both' where id = _uid and account_type = 'recipient';
  return public._ensure_my_donor();
end $$;

create or replace function public.set_my_availability(_status public.availability_status, _note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_active_user();
        _donor uuid := public._ensure_my_donor();
begin
  insert into public.donor_availability (donor_id, status, note, updated_by, updated_at)
  values (_donor, _status, public._clean(_note, 200), _uid, now())
  on conflict (donor_id) do update
    set status = excluded.status, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
end $$;

create or replace function public.respond_to_request(_request_id uuid, _message text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _donor uuid := public._ensure_my_donor();
  _req public.blood_requests;
  _id uuid;
begin
  select * into _req from public.blood_requests where id = _request_id;
  if not found then perform public._fail('Request not found.', 'P0002'); end if;
  if _req.status not in ('approved', 'active') then perform public._fail('This request is no longer accepting donors.'); end if;
  if _req.requester_id = _uid then perform public._fail('You cannot respond to your own request.'); end if;

  insert into public.request_responses (request_id, donor_id, responder_id, message)
  values (_request_id, _donor, _uid, public._clean(_message, 500))
  on conflict (request_id, donor_id) do update
    set status = 'responded', message = excluded.message, updated_at = now()
    where public.request_responses.status = 'withdrawn'
  returning id into _id;

  if _id is null then perform public._fail('You have already responded to this request.'); end if;
  return _id;
end $$;

create or replace function public.withdraw_response(_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare _donor uuid := public.my_donor_id();
begin
  perform public._require_active_user();
  update public.request_responses set status = 'withdrawn'
  where request_id = _request_id and donor_id = _donor and status = 'responded';
  if not found then perform public._fail('No active response to withdraw.', 'P0002'); end if;
end $$;

-- Self-reported donation (status 'recorded'; staff can verify later).
create or replace function public.record_donation(
  _request_id uuid default null, _hospital_name text default null, _hospital_id uuid default null,
  _donated_on date default current_date, _units int default 1
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _donor public.donors;
  _req public.blood_requests;
  _h public.hospitals;
  _name text := public._clean(_hospital_name, 160);
  _city int;
  _last date;
  _id uuid;
begin
  select * into _donor from public.donors where id = public._ensure_my_donor();
  if _donated_on is null or _donated_on > current_date then perform public._fail('Donation date cannot be in the future.'); end if;
  if _units not between 1 and 2 then perform public._fail('Units must be 1 or 2.'); end if;

  select max(donated_on) into _last from public.donations where donor_id = _donor.id;
  if _last is not null and _donated_on < _last + 56 and _donated_on >= _last then
    perform public._fail('Donations must be at least 56 days apart.');
  end if;

  if _request_id is not null then
    select * into _req from public.blood_requests where id = _request_id;
    if not found then perform public._fail('Request not found.', 'P0002'); end if;
    if not exists (select 1 from public.request_responses
                   where request_id = _request_id and donor_id = _donor.id and status <> 'withdrawn') then
      perform public._fail('Respond to this request before recording a donation for it.');
    end if;
    _name := _req.hospital_name; _city := _req.city_id; _hospital_id := coalesce(_hospital_id, _req.hospital_id);
  end if;
  if _hospital_id is not null then
    select * into _h from public.hospitals where id = _hospital_id;
    if found then _name := coalesce(_name, _h.name); _city := coalesce(_city, _h.city_id); end if;
  end if;
  if _name is null then perform public._fail('Hospital name is required.'); end if;

  insert into public.donations (donor_id, request_id, hospital_id, hospital_name, city_id, donated_on, units,
                                blood_group, recorded_by)
  values (_donor.id, _request_id, _hospital_id, _name, coalesce(_city, _donor.city_id), _donated_on, _units,
          _donor.blood_group, _uid)
  returning id into _id;

  if _request_id is not null then
    update public.request_responses set status = 'donated' where request_id = _request_id and donor_id = _donor.id;
  end if;

  insert into public.donor_availability (donor_id, status, updated_by) values (_donor.id, 'resting', _uid)
  on conflict (donor_id) do update set status = 'resting', updated_by = _uid, updated_at = now();

  perform public.notify_user(_uid, 'donation', 'Donation Recorded',
    format('Your donation at %s has been recorded. Thank you for saving lives!', _name), '/profile/donations');
  return _id;
end $$;

create or replace function public.mark_all_notifications_read()
returns integer language plpgsql security definer set search_path = '' as $$
declare _n int;
begin
  update public.notifications set read_at = now()
  where user_id = (select auth.uid()) and read_at is null;
  get diagnostics _n = row_count;
  return _n;
end $$;

-- Everything the app's Home/Profile header needs in one call.
create or replace function public.get_my_summary()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  _uid uuid := (select auth.uid());
  _donor uuid;
  _last date;
  _units int;
begin
  if _uid is null then return null; end if;
  select id into _donor from public.donors where profile_id = _uid;
  select max(donated_on), coalesce(sum(units), 0) into _last, _units from public.donations where donor_id = _donor;
  return jsonb_build_object(
    'donor_id', _donor,
    'donations', (select count(*) from public.donations where donor_id = _donor),
    'lives_saved', _units * 3,
    'accepted', (select count(*) from public.request_responses where donor_id = _donor and status <> 'withdrawn'),
    'my_requests', (select count(*) from public.blood_requests where requester_id = _uid),
    'open_requests', (select count(*) from public.blood_requests where status in ('approved','active')),
    'urgent_open', (select count(*) from public.blood_requests where status in ('approved','active') and urgency <> 'normal'),
    'unread', (select count(*) from public.notifications where user_id = _uid and read_at is null),
    'badges', (select count(*) from public.user_badges where user_id = _uid),
    'availability', (select status from public.donor_availability where donor_id = _donor),
    'last_donation', _last,
    'next_eligible', case when _last is null then current_date else (_last + interval '3 months')::date end,
    'is_admin', public.is_admin(),
    'is_staff', public.is_staff()
  );
end $$;

-- ============================================================================
-- REQUEST STATUS TRANSITIONS (staff + requester)
-- ============================================================================
--   pending  → approved | rejected | cancelled
--   approved → active | rejected | cancelled
--   active   → fulfilled | cancelled
--   fulfilled / rejected / cancelled are terminal
-- Staff (admin/moderator): every transition above.
-- Requester (own request): pending|approved|active → cancelled, active → fulfilled.
create or replace function public.transition_request_status(
  _request_id uuid, _to public.request_status, _reason text default null
) returns public.request_status
language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _staff boolean := public.is_staff();
  _req public.blood_requests;
  _allowed boolean;
  _reason_clean text := public._clean(_reason, 500);
begin
  select * into _req from public.blood_requests where id = _request_id for update;
  if not found then perform public._fail('Request not found.', 'P0002'); end if;
  if _req.status = _to then return _to; end if;

  _allowed := case _req.status
    when 'pending'  then _to in ('approved', 'rejected', 'cancelled')
    when 'approved' then _to in ('active', 'rejected', 'cancelled')
    when 'active'   then _to in ('fulfilled', 'cancelled')
    else false end;
  if not _allowed then
    perform public._fail(format('Cannot change a %s request to %s.', _req.status, _to));
  end if;

  if not _staff then
    if _req.requester_id is distinct from _uid then perform public._fail('You can only update your own requests.', '42501'); end if;
    if not (_to = 'cancelled' or (_to = 'fulfilled' and _req.status = 'active')) then
      perform public._fail('Only admins can approve or reject requests.', '42501');
    end if;
  end if;

  if _to = 'rejected' and _reason_clean is null then perform public._fail('A reason is required to reject a request.'); end if;

  update public.blood_requests set
    status        = _to,
    status_reason = _reason_clean,
    approved_by   = case when _to in ('approved','active') and approved_by is null then _uid else approved_by end,
    approved_at   = case when _to in ('approved','active') and approved_at is null then now() else approved_at end,
    fulfilled_at  = case when _to = 'fulfilled' then now() else fulfilled_at end,
    closed_at     = case when _to in ('fulfilled','rejected','cancelled') then now() else closed_at end
  where id = _request_id;

  if _staff and _req.requester_id is distinct from _uid then
    perform public._log_admin('request.' || _to, 'blood_request', _request_id::text,
      jsonb_build_object('from', _req.status, 'to', _to, 'reason', _reason_clean, 'reference', _req.reference_code));
  end if;
  return _to;
end $$;

-- ============================================================================
-- ADMIN / MODERATOR
-- ============================================================================

create or replace function public.admin_dashboard_stats()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform public._require_staff();
  return jsonb_build_object(
    'users',               (select count(*) from public.profiles),
    'suspended_users',     (select count(*) from public.profiles where status = 'suspended'),
    'donors',              (select count(*) from public.donors),
    'active_donors',       (select count(*) from public.donors where is_active),
    'available_donors',    (select count(*) from public.donor_availability a join public.donors d on d.id = a.donor_id
                             where d.is_active and a.status = 'available'),
    'pending_applications',(select count(*) from public.donor_applications where status = 'pending'),
    'requests_total',      (select count(*) from public.blood_requests),
    'requests_by_status',  (select coalesce(jsonb_object_agg(status, n), '{}') from
                              (select status, count(*) n from public.blood_requests group by status) s),
    'requests_by_source',  (select coalesce(jsonb_object_agg(source, n), '{}') from
                              (select source, count(*) n from public.blood_requests group by source) s),
    'hospitals',           (select count(*) from public.hospitals),
    'critical_stock',      (select count(*) from public.hospital_inventory where units <= 2),
    'unread_messages',     (select count(*) from public.contact_messages where read_at is null),
    'donations',           (select count(*) from public.donations)
  );
end $$;

create or replace function public.admin_review_donor_application(_application_id uuid, _approve boolean, _note text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_staff();
  _a public.donor_applications;
  _profile uuid;
  _donor uuid;
begin
  select * into _a from public.donor_applications where id = _application_id for update;
  if not found then perform public._fail('Application not found.', 'P0002'); end if;
  if _a.status <> 'pending' then perform public._fail('This application has already been reviewed.'); end if;

  if _approve then
    select id into _profile from public.profiles where email = _a.email;
    select id into _donor from public.donors where (profile_id = _profile and _profile is not null) or email = _a.email limit 1;
    if _donor is null then
      if _profile is not null then
        insert into public.donors (profile_id, blood_group, city_id, gender, age, is_verified, application_id)
        values (_profile, _a.blood_group, _a.city_id, _a.gender, _a.age, true, _a.id) returning id into _donor;
        update public.profiles set
          blood_group = coalesce(blood_group, _a.blood_group),
          city_id = coalesce(city_id, _a.city_id),
          phone = coalesce(phone, _a.phone)
        where id = _profile;
      else
        insert into public.donors (full_name, email, phone, age, gender, blood_group, city_id, is_verified, application_id)
        values (_a.full_name, _a.email, _a.phone, _a.age, _a.gender, _a.blood_group, _a.city_id, true, _a.id)
        returning id into _donor;
      end if;
      insert into public.donor_availability (donor_id, updated_by) values (_donor, _uid);
    end if;
    update public.donor_applications
      set status = 'approved', reviewed_by = _uid, reviewed_at = now(), review_note = public._clean(_note, 500), donor_id = _donor
      where id = _a.id;
    perform public.notify_user(coalesce(_a.submitted_by, _profile), 'system', 'Donor Application Approved',
      'Welcome to LifeLink! You are now listed as a blood donor.', '/profile');
  else
    update public.donor_applications
      set status = 'declined', reviewed_by = _uid, reviewed_at = now(), review_note = public._clean(_note, 500)
      where id = _a.id;
  end if;

  perform public._log_admin(case when _approve then 'application.approve' else 'application.decline' end,
    'donor_application', _a.id::text, jsonb_build_object('email', _a.email, 'note', _note, 'donor_id', _donor));
  return _donor;
end $$;

create or replace function public.admin_set_donor_active(_donor_id uuid, _active boolean, _reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_staff();
  update public.donors set is_active = _active where id = _donor_id;
  if not found then perform public._fail('Donor not found.', 'P0002'); end if;
  perform public._log_admin(case when _active then 'donor.activate' else 'donor.deactivate' end,
    'donor', _donor_id::text, jsonb_build_object('reason', _reason));
end $$;

create or replace function public.admin_set_donor_availability(_donor_id uuid, _status public.availability_status)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_staff();
begin
  if not exists (select 1 from public.donors where id = _donor_id) then perform public._fail('Donor not found.', 'P0002'); end if;
  insert into public.donor_availability (donor_id, status, updated_by) values (_donor_id, _status, _uid)
  on conflict (donor_id) do update set status = excluded.status, updated_by = _uid, updated_at = now();
  perform public._log_admin('donor.availability', 'donor', _donor_id::text, jsonb_build_object('status', _status));
end $$;

create or replace function public.admin_verify_donation(_donation_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_staff();
begin
  update public.donations set status = 'verified', verified_by = _uid, verified_at = now() where id = _donation_id;
  if not found then perform public._fail('Donation not found.', 'P0002'); end if;
  perform public._log_admin('donation.verify', 'donation', _donation_id::text);
end $$;

create or replace function public.admin_set_user_role(_user_id uuid, _role public.app_role, _grant boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_admin();
begin
  if _user_id = _uid and _role = 'admin' and not _grant then
    perform public._fail('You cannot remove your own admin role.', '42501');
  end if;
  if not exists (select 1 from public.profiles where id = _user_id) then perform public._fail('User not found.', 'P0002'); end if;
  if _grant then
    insert into public.user_roles (user_id, role, granted_by) values (_user_id, _role, _uid) on conflict do nothing;
  else
    delete from public.user_roles where user_id = _user_id and role = _role;
  end if;
  perform public._log_admin(case when _grant then 'role.grant' else 'role.revoke' end, 'user', _user_id::text,
    jsonb_build_object('role', _role));
end $$;

-- Suspension blocks all writes (every RPC and owner policy requires status = active).
create or replace function public.admin_set_account_status(_user_id uuid, _status public.account_status, _reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_admin();
begin
  if _user_id = _uid then perform public._fail('You cannot change your own account status.', '42501'); end if;
  if _status = 'suspended' and public._clean(_reason, 300) is null then perform public._fail('A reason is required to suspend an account.'); end if;
  update public.profiles set status = _status,
         suspended_reason = case when _status = 'suspended' then public._clean(_reason, 300) end
  where id = _user_id;
  if not found then perform public._fail('User not found.', 'P0002'); end if;
  perform public._log_admin('user.' || _status, 'user', _user_id::text, jsonb_build_object('reason', _reason));
end $$;

create or replace function public.admin_set_verified(_user_id uuid, _verified boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_staff();
  update public.profiles set is_verified = _verified where id = _user_id;
  if not found then perform public._fail('User not found.', 'P0002'); end if;
  update public.donors set is_verified = _verified where profile_id = _user_id;
  perform public._log_admin(case when _verified then 'user.verify' else 'user.unverify' end, 'user', _user_id::text);
end $$;

create or replace function public.admin_assign_hospital_staff(_user_id uuid, _hospital_id uuid, _assign boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare _uid uuid := public._require_admin();
begin
  if _assign then
    insert into public.hospital_staff (user_id, hospital_id) values (_user_id, _hospital_id) on conflict do nothing;
    insert into public.user_roles (user_id, role, granted_by) values (_user_id, 'hospital_staff', _uid) on conflict do nothing;
  else
    delete from public.hospital_staff where user_id = _user_id and hospital_id = _hospital_id;
    if not exists (select 1 from public.hospital_staff where user_id = _user_id) then
      delete from public.user_roles where user_id = _user_id and role = 'hospital_staff';
    end if;
  end if;
  perform public._log_admin(case when _assign then 'hospital_staff.assign' else 'hospital_staff.remove' end,
    'hospital', _hospital_id::text, jsonb_build_object('user_id', _user_id));
end $$;

-- Bulk-safe inventory update used by the dashboard (one row per group).
create or replace function public.set_hospital_inventory(_hospital_id uuid, _blood_group text, _units int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_active_user();
  if not public.manages_hospital(_hospital_id) then perform public._fail('Not allowed to manage this hospital.', '42501'); end if;
  if _units is null or _units < 0 then perform public._fail('Units cannot be negative.'); end if;
  if not exists (select 1 from public.blood_groups where code = _blood_group) then perform public._fail('Invalid blood group.'); end if;
  insert into public.hospital_inventory (hospital_id, blood_group, units) values (_hospital_id, _blood_group, _units)
  on conflict (hospital_id, blood_group) do update set units = excluded.units;
  perform public._log_admin('inventory.update', 'hospital', _hospital_id::text,
    jsonb_build_object('blood_group', _blood_group, 'units', _units));
end $$;

-- One-time bootstrap of the first admin. NOT callable by clients; run it from
-- the Supabase SQL editor (or psql) as the database owner:
--   select public.bootstrap_admin('you@example.com');
create or replace function public.bootstrap_admin(_email text)
returns void language plpgsql security definer set search_path = '' as $$
declare _id uuid;
begin
  select id into _id from public.profiles where email = _email;
  if _id is null then raise exception 'No account with email % — sign up first.', _email; end if;
  insert into public.user_roles (user_id, role) values (_id, 'admin') on conflict do nothing;
  update public.profiles set is_verified = true where id = _id;
end $$;

-- ============================================================================
-- EXECUTE privileges (explicit allow-list)
-- ============================================================================
do $$
declare f record;
begin
  -- lock down every function in public first
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- policy helpers (needed by RLS evaluation)
grant execute on function public.has_role(public.app_role), public.is_admin(), public.is_staff(),
  public.is_active_user(), public.manages_hospital(uuid) to anon, authenticated;
grant execute on function public.my_donor_id() to authenticated;

-- public API
grant execute on function
  public.submit_blood_request(jsonb),
  public.submit_donor_application(jsonb),
  public.submit_contact_message(jsonb),
  public.search_donors(text, text, text, boolean, text, int, int),
  public.get_donor_public(uuid),
  public.list_public_requests(text, text, boolean, boolean, int, int),
  public.public_stats()
to anon, authenticated;

-- signed-in API
grant execute on function
  public.get_donor_contact(uuid),
  public.register_as_donor(text, text, text),
  public.set_my_availability(public.availability_status, text),
  public.respond_to_request(uuid, text),
  public.withdraw_response(uuid),
  public.record_donation(uuid, text, uuid, date, int),
  public.mark_all_notifications_read(),
  public.get_my_summary(),
  public.transition_request_status(uuid, public.request_status, text),
  public.admin_dashboard_stats(),
  public.admin_review_donor_application(uuid, boolean, text),
  public.admin_set_donor_active(uuid, boolean, text),
  public.admin_set_donor_availability(uuid, public.availability_status),
  public.admin_verify_donation(uuid),
  public.admin_set_user_role(uuid, public.app_role, boolean),
  public.admin_set_account_status(uuid, public.account_status, text),
  public.admin_set_verified(uuid, boolean),
  public.admin_assign_hospital_staff(uuid, uuid, boolean),
  public.set_hospital_inventory(uuid, text, int)
to authenticated;
-- (admin_* functions re-check is_admin()/is_staff() inside; granting EXECUTE
--  to authenticated only makes them reachable, not usable, by non-admins.)

-- public._clean / _valid_* are immutable helpers used in policies? No — internal only.
-- bootstrap_admin intentionally has NO client grant.
