-- ============================================================================
-- LifeLink Platform — 0007: client read models + admin management API
--
-- Every client (website, Android app, admin dashboard) reads through these
-- functions instead of hand-written joins, so all three see exactly the same
-- shape of data and the same visibility rules. All functions re-check the
-- caller's role inside; EXECUTE grants only make them reachable.
-- ============================================================================

-- ── Hospitals (public) ──────────────────────────────────────────────────────
create or replace function public.list_hospitals(_city text default null, _id uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(h order by h->>'name'), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', x.id, 'name', x.name, 'type', x.type, 'has_blood_bank', x.has_blood_bank,
      'city', c.name, 'city_id', x.city_id, 'address', x.address, 'phone', x.phone, 'email', x.email,
      'latitude', x.latitude, 'longitude', x.longitude, 'open_24h', x.open_24h,
      'opening_hours', x.opening_hours, 'beds', x.beds, 'rating', x.rating,
      'reviews_count', x.reviews_count, 'about', x.about, 'services', to_jsonb(x.services),
      'is_verified', x.is_verified, 'is_active', x.is_active, 'created_at', x.created_at,
      'inventory', coalesce((select jsonb_object_agg(i.blood_group, i.units)
                               from public.hospital_inventory i where i.hospital_id = x.id), '{}'::jsonb),
      'inventory_updated_at', (select max(i.updated_at) from public.hospital_inventory i where i.hospital_id = x.id)
    ) as h
    from public.hospitals x
    join public.cities c on c.id = x.city_id
    where (x.is_active or public.is_admin() or public.manages_hospital(x.id))
      and (_id is null or x.id = _id)
      and (_city is null or trim(_city) = '' or c.name_key = lower(trim(_city)))
  ) s;
$$;

-- ── Donor profile (public, no contact details) ──────────────────────────────
create or replace function public.get_donor_details(_donor_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', d.id, 'full_name', coalesce(p.full_name, d.full_name), 'blood_group', d.blood_group,
    'city', c.name, 'area', d.area, 'gender', coalesce(p.gender, d.gender),
    'age', coalesce(d.age, extract(year from age(p.date_of_birth))::int),
    'availability', coalesce(a.status, 'available'),
    'donations_count', (select count(*) from public.donations x where x.donor_id = d.id),
    'rating', d.rating, 'rating_count', d.rating_count,
    'is_verified', (d.is_verified or coalesce(p.is_verified, false)),
    'hours', d.hours, 'about', d.about,
    'last_donation_on', (select max(x.donated_on) from public.donations x where x.donor_id = d.id),
    'member_since', coalesce(p.created_at, d.created_at))
  from public.donors d
  join public.cities c on c.id = d.city_id
  left join public.profiles p on p.id = d.profile_id
  left join public.donor_availability a on a.donor_id = d.id
  left join public.notification_preferences np on np.user_id = d.profile_id
  where d.id = _donor_id and d.is_active and (p.id is null or p.status = 'active') and coalesce(np.show_in_search, true);
$$;

-- ── Shared request JSON builder (internal) ──────────────────────────────────
-- _with_contact: contact name/phone are only included for signed-in callers.
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
    'responded_count', (select count(*) from public.request_responses rr
                         where rr.request_id = r.id and rr.status <> 'withdrawn'),
    'is_mine', coalesce(r.requester_id = (select auth.uid()), false),
    'my_response', (select rr.status from public.request_responses rr
                     where rr.request_id = r.id and rr.responder_id = (select auth.uid()))
  );
$$;

-- ── Requests for signed-in users (app feed, "My Requests", details) ──────────
-- Same visibility as RLS: approved/active/fulfilled + own requests (+ staff: all).
create or replace function public.list_requests(
  _scope text default 'feed',     -- feed | mine
  _id uuid default null,
  _limit int default 200
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  _uid uuid := (select auth.uid());
  _staff boolean := public.is_staff();
begin
  if _uid is null then perform public._fail('Please sign in to continue.', '42501'); end if;
  return coalesce((
    select jsonb_agg(public._request_json(r.rec, true) order by r.created_at desc)
    from (
      select b as rec, b.created_at from public.blood_requests b
      where (_id is null or b.id = _id)
        and case when _scope = 'mine' then b.requester_id = _uid
                 else (b.status in ('approved', 'active', 'fulfilled') or b.requester_id = _uid or _staff) end
      order by b.created_at desc
      limit least(greatest(coalesce(_limit, 200), 1), 500)
    ) r
  ), '[]'::jsonb);
end $$;

-- ── My profile (app header, edit profile) ───────────────────────────────────
create or replace function public.get_my_profile()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _uid uuid := (select auth.uid());
begin
  if _uid is null then return null; end if;
  return (
    select jsonb_build_object(
      'id', p.id, 'full_name', p.full_name, 'email', p.email, 'phone', p.phone,
      'blood_group', p.blood_group, 'account_type', p.account_type, 'city', c.name, 'city_id', p.city_id,
      'area', p.area, 'date_of_birth', p.date_of_birth, 'gender', p.gender, 'weight_kg', p.weight_kg,
      'avatar_path', p.avatar_path, 'is_verified', p.is_verified, 'status', p.status,
      'created_at', p.created_at,
      'roles', coalesce((select jsonb_agg(ur.role) from public.user_roles ur where ur.user_id = p.id), '[]'::jsonb),
      'donor', (select jsonb_build_object(
                  'id', d.id, 'availability', coalesce(a.status, 'available'), 'rating', d.rating,
                  'rating_count', d.rating_count, 'area', d.area, 'hours', d.hours, 'about', d.about,
                  'is_active', d.is_active)
                from public.donors d left join public.donor_availability a on a.donor_id = d.id
                where d.profile_id = p.id),
      'preferences', (select to_jsonb(np) - 'user_id' from public.notification_preferences np where np.user_id = p.id)
    )
    from public.profiles p left join public.cities c on c.id = p.city_id
    where p.id = _uid
  );
end $$;

-- Update own profile. Accepts city by name; keeps the donor row in sync.
create or replace function public.update_my_profile(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  _uid uuid := public._require_active_user();
  _city integer;
  _group text := upper(public._clean(p->>'blood_group', 3));
  _phone text := public._clean(p->>'phone', 30);
  _name text := public._clean(p->>'full_name', 100);
begin
  if p ? 'full_name' and (_name is null or char_length(_name) < 2) then perform public._fail('Please enter your full name.'); end if;
  if p ? 'phone' and _phone is not null and not public._valid_phone(_phone) then perform public._fail('Please enter a valid phone number.'); end if;
  if p ? 'blood_group' and _group is not null and _group not in ('A+','A-','B+','B-','AB+','AB-','O+','O-') then
    perform public._fail('Please choose a valid blood group.');
  end if;
  if public._clean(p->>'city', 80) is not null then _city := public.resolve_city(p->>'city'); end if;
  if p ? 'gender' and coalesce(p->>'gender', '') not in ('', 'male', 'female', 'other') then perform public._fail('Invalid gender.'); end if;

  update public.profiles set
    full_name     = case when p ? 'full_name' then _name else full_name end,
    phone         = case when p ? 'phone' then _phone else phone end,
    blood_group   = case when p ? 'blood_group' then _group else blood_group end,
    city_id       = coalesce(_city, city_id),
    area          = case when p ? 'area' then public._clean(p->>'area', 120) else area end,
    account_type  = case when p->>'account_type' in ('donor','recipient','both') then (p->>'account_type')::public.account_type else account_type end,
    date_of_birth = case when p ? 'date_of_birth' then nullif(p->>'date_of_birth', '')::date else date_of_birth end,
    gender        = case when p ? 'gender' then nullif(p->>'gender', '')::public.gender else gender end,
    weight_kg     = case when p ? 'weight_kg' then nullif(p->>'weight_kg', '')::numeric else weight_kg end,
    avatar_path   = case when p ? 'avatar_path' then public._clean(p->>'avatar_path', 300) else avatar_path end
  where id = _uid;

  -- keep the linked donor record consistent (sync_profile_to_donor covers group/city)
  update public.donors set
    area  = case when p ? 'area' then public._clean(p->>'area', 120) else area end,
    hours = case when p ? 'hours' then public._clean(p->>'hours', 40) else hours end,
    about = case when p ? 'about' then public._clean(p->>'about', 500) else about end
  where profile_id = _uid;

  -- becoming a donor from the profile screen
  if p->>'account_type' in ('donor', 'both') and not exists (select 1 from public.donors where profile_id = _uid) then
    begin perform public.register_as_donor(); exception when others then null; end;
  end if;

  return public.get_my_profile();
end $$;

-- ── My donations + badges ───────────────────────────────────────────────────
create or replace function public.list_my_donations()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _donor uuid := public.my_donor_id();
begin
  if (select auth.uid()) is null then perform public._fail('Please sign in to continue.', '42501'); end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', d.id, 'hospital_name', d.hospital_name, 'hospital_id', d.hospital_id,
      'city', (select c.name from public.cities c where c.id = d.city_id),
      'donated_on', d.donated_on, 'units', d.units, 'blood_group', d.blood_group,
      'request_id', d.request_id, 'certificate_no', d.certificate_no, 'status', d.status,
      'created_at', d.created_at) order by d.donated_on desc, d.created_at desc)
    from public.donations d where d.donor_id = _donor
  ), '[]'::jsonb);
end $$;

create or replace function public.list_my_badges()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  _uid uuid := (select auth.uid());
  _donor uuid := public.my_donor_id();
  _donations int := 0; _units int := 0; _urgent int := 0;
begin
  if _uid is null then perform public._fail('Please sign in to continue.', '42501'); end if;
  select count(*), coalesce(sum(units), 0) into _donations, _units from public.donations where donor_id = _donor;
  select count(*) into _urgent
    from public.request_responses rr join public.blood_requests br on br.id = rr.request_id
    where rr.donor_id = _donor and rr.status <> 'withdrawn' and br.urgency <> 'normal';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', b.id, 'title', b.title, 'description', b.description, 'requirement', b.requirement,
      'icon', b.icon, 'tone', b.tone, 'earned_at', ub.earned_at,
      'progress', case when ub.earned_at is not null then 1
                       else least(1, round((case b.metric when 'donations' then _donations
                                                          when 'urgent_responses' then _urgent
                                                          when 'lives_saved' then _units * 3
                                                          else 0 end)::numeric / b.threshold, 2)) end
    ) order by b.sort_order)
    from public.badges b
    left join public.user_badges ub on ub.badge_id = b.id and ub.user_id = _uid
  ), '[]'::jsonb);
end $$;

-- ============================================================================
-- ADMIN / STAFF read models
-- ============================================================================
create or replace function public.admin_list_requests(
  _status text default null, _source text default null, _blood_group text default null,
  _city text default null, _search text default null, _urgency text default null,
  _limit int default 50, _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _q text := public._clean(_search, 80);
begin
  perform public._require_staff();
  return (
    with f as (
      select r as rec, r.created_at from public.blood_requests r
      join public.cities c on c.id = r.city_id
      where (nullif(_status, '') is null or r.status::text = _status)
        and (nullif(_source, '') is null or r.source::text = _source)
        and (nullif(_blood_group, '') is null or r.blood_group = upper(_blood_group))
        and (nullif(_urgency, '') is null or r.urgency::text = _urgency)
        and (nullif(trim(coalesce(_city, '')), '') is null or c.name_key like '%' || lower(trim(_city)) || '%')
        and (_q is null or r.patient_name::text ilike '%' || _q || '%' or r.hospital_name ilike '%' || _q || '%'
             or r.reference_code ilike '%' || _q || '%' or r.contact_phone::text ilike '%' || _q || '%'
             or c.name ilike '%' || _q || '%')
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'rows', coalesce((select jsonb_agg(
                 public._request_json(x.rec, true) || jsonb_build_object(
                   'requester', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email)
                                 from public.profiles p where p.id = (x.rec).requester_id))
                 order by x.created_at desc)
               from (select * from f order by created_at desc
                     limit least(greatest(coalesce(_limit, 50), 1), 500) offset greatest(coalesce(_offset, 0), 0)) x), '[]'::jsonb)
    )
  );
end $$;

create or replace function public.admin_get_request(_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _r public.blood_requests;
begin
  perform public._require_staff();
  select * into _r from public.blood_requests where id = _id;
  if _r.id is null then perform public._fail('Request not found.', 'P0002'); end if;
  return public._request_json(_r, true) || jsonb_build_object(
    'requester', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email, 'phone', p.phone,
                                            'is_verified', p.is_verified)
                  from public.profiles p where p.id = _r.requester_id),
    'approved_by_name', (select p.full_name from public.profiles p where p.id = _r.approved_by),
    'history', coalesce((select jsonb_agg(jsonb_build_object(
                   'from', h.from_status, 'to', h.to_status, 'reason', h.reason, 'at', h.changed_at,
                   'by', (select p.full_name from public.profiles p where p.id = h.changed_by)) order by h.changed_at)
                 from public.request_status_history h where h.request_id = _r.id), '[]'::jsonb),
    'responses', coalesce((select jsonb_agg(jsonb_build_object(
                   'id', rr.id, 'status', rr.status, 'message', rr.message, 'created_at', rr.created_at,
                   'donor_id', d.id, 'donor_name', coalesce(p.full_name, d.full_name), 'blood_group', d.blood_group,
                   'phone', coalesce(p.phone, d.phone)) order by rr.created_at)
                 from public.request_responses rr join public.donors d on d.id = rr.donor_id
                 left join public.profiles p on p.id = d.profile_id
                 where rr.request_id = _r.id), '[]'::jsonb)
  );
end $$;

create or replace function public.admin_list_donors(
  _search text default null, _blood_group text default null, _availability text default null,
  _active boolean default null, _limit int default 50, _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _q text := public._clean(_search, 80);
begin
  perform public._require_staff();
  return (
    with f as (
      select d.id, coalesce(p.full_name, d.full_name)::text as full_name,
             coalesce(p.email, d.email)::text as email, coalesce(p.phone, d.phone)::text as phone,
             d.age, coalesce(p.gender, d.gender) as gender, d.blood_group, c.name as city, d.area,
             d.is_active, (d.is_verified or coalesce(p.is_verified, false)) as is_verified,
             coalesce(a.status, 'available'::public.availability_status) as availability, a.updated_at as availability_updated_at,
             (select count(*) from public.donations x where x.donor_id = d.id) as donations_count,
             (select max(x.donated_on) from public.donations x where x.donor_id = d.id) as last_donation_on,
             d.profile_id, case when d.profile_id is null then 'website' else 'account' end as kind,
             p.status as account_status, d.created_at
      from public.donors d
      join public.cities c on c.id = d.city_id
      left join public.profiles p on p.id = d.profile_id
      left join public.donor_availability a on a.donor_id = d.id
      where (nullif(_blood_group, '') is null or d.blood_group = upper(_blood_group))
        and (nullif(_availability, '') is null or coalesce(a.status, 'available')::text = _availability)
        and (_active is null or d.is_active = _active)
        and (_q is null or coalesce(p.full_name, d.full_name)::text ilike '%' || _q || '%'
             or coalesce(p.email, d.email)::text ilike '%' || _q || '%' or c.name ilike '%' || _q || '%'
             or coalesce(p.phone, d.phone)::text ilike '%' || _q || '%' or d.blood_group ilike _q)
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc)
               from (select * from f order by created_at desc
                     limit least(greatest(coalesce(_limit, 50), 1), 500) offset greatest(coalesce(_offset, 0), 0)) x), '[]'::jsonb)
    )
  );
end $$;

create or replace function public.admin_list_users(
  _search text default null, _role text default null, _status text default null,
  _limit int default 50, _offset int default 0
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _q text := public._clean(_search, 80);
begin
  perform public._require_staff();
  return (
    with f as (
      select p.id, p.full_name::text as full_name, p.email::text as email, p.phone::text as phone,
             p.account_type, c.name as city, p.blood_group, p.is_verified, p.status, p.suspended_reason, p.created_at,
             coalesce((select jsonb_agg(ur.role order by ur.role) from public.user_roles ur where ur.user_id = p.id), '[]'::jsonb) as roles,
             (select d.id from public.donors d where d.profile_id = p.id) as donor_id,
             (select count(*) from public.blood_requests b where b.requester_id = p.id) as requests_count
      from public.profiles p left join public.cities c on c.id = p.city_id
      where (nullif(_status, '') is null or p.status::text = _status)
        and (nullif(_role, '') is null or exists (select 1 from public.user_roles ur where ur.user_id = p.id and ur.role::text = _role))
        and (_q is null or p.full_name::text ilike '%' || _q || '%' or p.email::text ilike '%' || _q || '%'
             or coalesce(p.phone::text, '') ilike '%' || _q || '%')
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'rows', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc)
               from (select * from f order by created_at desc
                     limit least(greatest(coalesce(_limit, 50), 1), 500) offset greatest(coalesce(_offset, 0), 0)) x), '[]'::jsonb)
    )
  );
end $$;

create or replace function public.admin_list_applications(_status text default null, _search text default null, _limit int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _q text := public._clean(_search, 80);
begin
  perform public._require_staff();
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select a.id, a.full_name::text as full_name, a.email::text as email, a.phone::text as phone, a.age, a.gender,
             a.blood_group, c.name as city, a.status, a.source, a.review_note, a.reviewed_at,
             (select p.full_name from public.profiles p where p.id = a.reviewed_by) as reviewed_by_name,
             a.donor_id, a.created_at
      from public.donor_applications a join public.cities c on c.id = a.city_id
      where (nullif(_status, '') is null or a.status::text = _status)
        and (_q is null or a.full_name::text ilike '%' || _q || '%' or a.email::text ilike '%' || _q || '%'
             or c.name ilike '%' || _q || '%' or a.blood_group ilike _q)
      order by a.created_at desc
      limit least(greatest(coalesce(_limit, 200), 1), 1000)
    ) x
  ), '[]'::jsonb);
end $$;

create or replace function public.admin_list_logs(_kind text default 'activity', _table text default null, _limit int default 100, _offset int default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare _lim int := least(greatest(coalesce(_limit, 100), 1), 500);
        _off int := greatest(coalesce(_offset, 0), 0);
begin
  perform public._require_admin();
  if _kind = 'audit' then
    return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (
      select l.id, l.table_name, l.record_id, l.action, l.old_data, l.new_data, l.actor_id,
             (select p.full_name from public.profiles p where p.id = l.actor_id) as actor_name, l.created_at
      from public.audit_logs l
      where nullif(_table, '') is null or l.table_name = _table
      order by l.id desc limit _lim offset _off) x), '[]'::jsonb);
  end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (
    select l.id, l.action, l.target_type, l.target_id, l.details, l.admin_id,
           (select p.full_name from public.profiles p where p.id = l.admin_id) as admin_name, l.created_at
    from public.admin_activity_logs l
    where nullif(_table, '') is null or l.target_type = _table
    order by l.id desc limit _lim offset _off) x), '[]'::jsonb);
end $$;

-- ============================================================================
-- ADMIN writes
-- ============================================================================
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
      is_verified = case when public.is_admin() then coalesce((p->>'is_verified')::boolean, is_verified) else is_verified end,
      is_active   = case when public.is_admin() then coalesce((p->>'is_active')::boolean, is_active) else is_active end
    where id = _id;
    if not found then perform public._fail('Hospital not found.', 'P0002'); end if;
    perform public._log_admin('hospital.update', 'hospital', _id::text, jsonb_build_object('name', _name));
  end if;
  return _id;
end $$;

create or replace function public.admin_delete_request(_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_admin();
  delete from public.blood_requests where id = _request_id;
  if not found then perform public._fail('Request not found.', 'P0002'); end if;
  perform public._log_admin('request.delete', 'blood_request', _request_id::text);
end $$;

create or replace function public.admin_delete_application(_application_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._require_admin();
  delete from public.donor_applications where id = _application_id and status <> 'pending';
  if not found then perform public._fail('Only reviewed applications can be removed.', 'P0002'); end if;
  perform public._log_admin('application.delete', 'donor_application', _application_id::text);
end $$;

-- Send an in-app notification to one user, all donors, or a filtered group.
create or replace function public.admin_send_notification(
  _audience text, _title text, _body text,
  _user_id uuid default null, _city text default null, _blood_group text default null
) returns integer language plpgsql security definer set search_path = '' as $$
declare
  _t text := public._clean(_title, 120);
  _b text := public._clean(_body, 500);
  _n integer;
begin
  perform public._require_staff();
  if _t is null or _b is null then perform public._fail('Title and message are required.'); end if;
  if _audience not in ('user', 'donors', 'all') then perform public._fail('Invalid audience.'); end if;
  if _audience = 'user' and _user_id is null then perform public._fail('Choose a user.'); end if;

  insert into public.notifications (user_id, type, title, body, data)
  select p.id, 'system', _t, _b, jsonb_build_object('broadcast', _audience <> 'user')
  from public.profiles p
  left join public.donors d on d.profile_id = p.id
  left join public.cities c on c.id = coalesce(d.city_id, p.city_id)
  where p.status = 'active'
    and case _audience when 'user' then p.id = _user_id
                       when 'donors' then d.id is not null and d.is_active
                       else true end
    and (nullif(trim(coalesce(_city, '')), '') is null or c.name_key = lower(trim(_city)))
    and (nullif(_blood_group, '') is null or coalesce(d.blood_group, p.blood_group) = upper(_blood_group));
  get diagnostics _n = row_count;
  perform public._log_admin('notification.send', 'notification', null,
    jsonb_build_object('audience', _audience, 'title', _t, 'recipients', _n, 'city', _city, 'blood_group', _blood_group));
  return _n;
end $$;

-- ── Grants ──────────────────────────────────────────────────────────────────
-- New functions get EXECUTE for PUBLIC by default (a global default that the
-- per-schema revoke in 0004 cannot remove), so revoke explicitly, then allow-list.
revoke execute on function
  public._request_json(public.blood_requests, boolean),
  public.list_hospitals(text, uuid),
  public.get_donor_details(uuid),
  public.list_requests(text, uuid, int),
  public.get_my_profile(),
  public.update_my_profile(jsonb),
  public.list_my_donations(),
  public.list_my_badges(),
  public.admin_list_requests(text, text, text, text, text, text, int, int),
  public.admin_get_request(uuid),
  public.admin_list_donors(text, text, text, boolean, int, int),
  public.admin_list_users(text, text, text, int, int),
  public.admin_list_applications(text, text, int),
  public.admin_list_logs(text, text, int, int),
  public.admin_upsert_hospital(jsonb),
  public.admin_delete_request(uuid),
  public.admin_delete_application(uuid),
  public.admin_send_notification(text, text, text, uuid, text, text)
from public, anon, authenticated;

grant execute on function public.list_hospitals(text, uuid), public.get_donor_details(uuid) to anon, authenticated;

grant execute on function
  public.list_requests(text, uuid, int),
  public.get_my_profile(),
  public.update_my_profile(jsonb),
  public.list_my_donations(),
  public.list_my_badges(),
  public.admin_list_requests(text, text, text, text, text, text, int, int),
  public.admin_get_request(uuid),
  public.admin_list_donors(text, text, text, boolean, int, int),
  public.admin_list_users(text, text, text, int, int),
  public.admin_list_applications(text, text, int),
  public.admin_list_logs(text, text, int, int),
  public.admin_upsert_hospital(jsonb),
  public.admin_delete_request(uuid),
  public.admin_delete_application(uuid),
  public.admin_send_notification(text, text, text, uuid, text, text)
to authenticated;
