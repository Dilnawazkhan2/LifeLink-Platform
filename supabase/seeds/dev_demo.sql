-- ============================================================================
-- DEVELOPMENT / DEMO DATA ONLY — never run against production.
-- Loaded automatically by `supabase db reset` on the LOCAL stack.
-- Test credentials (local only):
--   admin@lifelink.dev        / LifeLinkAdmin#2026   (admin)
--   umer.abdullah@email.com   / lifelink123          (verified donor, O+, Karachi)
--   ahmed.raza@email.com      / lifelink123          (donor, O+)
--   zainab.farooq@email.com   / lifelink123          (donor, AB+)
--   kamran.siddiqui@email.com / lifelink123          (recipient, unverified)
-- ============================================================================

create or replace function pg_temp.mk_user(_email text, _password text, _meta jsonb)
returns uuid language plpgsql as $$
declare _id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', _id, 'authenticated', 'authenticated', _email,
    extensions.crypt(_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', _meta, now() - interval '2 years', now(),
    '', '', '', ''
  );
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), _id, _id::text,
          jsonb_build_object('sub', _id::text, 'email', _email, 'email_verified', true),
          'email', now(), now(), now());
  return _id;
end $$;

do $$
declare
  _admin uuid; _umer uuid; _ahmed uuid; _zainab uuid; _kamran uuid;
  _umer_donor uuid; _bilal uuid; _khi int; _lhe int;
  _akuh uuid; _lnh uuid; _civil uuid; _skmch uuid;
  _r_raza uuid; _r_ayesha uuid;
begin
  select id into _khi from public.cities where name = 'Karachi';
  select id into _lhe from public.cities where name = 'Lahore';
  select id into _akuh  from public.hospitals where name = 'Aga Khan University Hospital';
  select id into _lnh   from public.hospitals where name = 'Liaquat National Hospital';
  select id into _civil from public.hospitals where name = 'Civil Hospital Karachi';
  select id into _skmch from public.hospitals where name = 'Shaukat Khanum Memorial Cancer Hospital';

  -- ── Accounts (profiles/donors are created by the handle_new_user trigger) ──
  _admin := pg_temp.mk_user('admin@lifelink.dev', 'LifeLinkAdmin#2026',
    '{"full_name":"LifeLink Admin","account_type":"recipient","city":"Karachi"}');
  _umer := pg_temp.mk_user('umer.abdullah@email.com', 'lifelink123',
    '{"full_name":"Umer Abdullah","account_type":"both","phone":"+92-300-5551234","blood_group":"O+","city":"Karachi","area":"DHA Phase 6"}');
  _ahmed := pg_temp.mk_user('ahmed.raza@email.com', 'lifelink123',
    '{"full_name":"Ahmed Raza","account_type":"donor","phone":"+92-333-7812450","blood_group":"O+","city":"Karachi","area":"DHA Phase 5"}');
  _zainab := pg_temp.mk_user('zainab.farooq@email.com', 'lifelink123',
    '{"full_name":"Zainab Farooq","account_type":"donor","phone":"+92-300-9087612","blood_group":"AB+","city":"Karachi","area":"North Nazimabad"}');
  _kamran := pg_temp.mk_user('kamran.siddiqui@email.com', 'lifelink123',
    '{"full_name":"Kamran Siddiqui","account_type":"recipient","phone":"+92-333-1239876","city":"Karachi"}');

  insert into public.user_roles (user_id, role) values (_admin, 'admin');
  update public.profiles set is_verified = true, gender = 'male', date_of_birth = '1999-03-14', weight_kg = 72
    where id = _umer;
  update public.profiles set is_verified = true where id in (_admin, _ahmed, _zainab);
  update public.donors set is_verified = true, hours = '9 AM – 9 PM', rating = 4.9, rating_count = 31 where profile_id = _ahmed;
  update public.donors set is_verified = true, hours = '10 AM – 6 PM', rating = 4.8, rating_count = 18 where profile_id = _zainab;
  update public.donors set is_verified = true, rating = 4.8, rating_count = 12 where profile_id = _umer
    returning id into _umer_donor;

  -- ── Website-approved donors without accounts ─────────────────────────────
  insert into public.donors (full_name, email, phone, age, gender, blood_group, city_id, area, hours, is_verified, rating, rating_count)
  values ('Bilal Hussain', 'bilal.hussain@email.com', '+92-321-2456789', 31, 'male', 'O-', _khi, 'Clifton Block 4', '8 AM – 10 PM', true, 4.9, 42)
  returning id into _bilal;
  insert into public.donor_availability (donor_id) values (_bilal);

  insert into public.donors (full_name, email, phone, age, gender, blood_group, city_id, area, is_verified, rating, rating_count)
  values ('Sana Tariq', 'sana.tariq@email.com', '+92-321-4567321', 30, 'female', 'A+', _lhe, 'Gulberg III', true, 4.8, 27);
  insert into public.donor_availability (donor_id, status)
  select id, 'busy' from public.donors where email = 'sana.tariq@email.com';

  -- pending website application (for the dashboard review queue)
  insert into public.donor_applications (full_name, email, phone, age, gender, blood_group, city_id)
  values ('Hira Shah', 'hira.shah@email.com', '+92-302-4455123', 24, 'female', 'B+', (select id from public.cities where name = 'Hyderabad'));

  -- ── Umer's donation history (7 donations → Regular Donor badge) ──────────
  insert into public.donations (donor_id, hospital_id, hospital_name, city_id, donated_on, blood_group, status, recorded_by)
  values
    (_umer_donor, _akuh,  'Aga Khan University Hospital', _khi, '2024-08-15', 'O+', 'verified', _umer),
    (_umer_donor, _lnh,   'Liaquat National Hospital',    _khi, '2024-05-10', 'O+', 'verified', _umer),
    (_umer_donor, null,   'South City Hospital',          _khi, '2024-02-20', 'O+', 'verified', _umer),
    (_umer_donor, null,   'Jinnah Postgraduate Medical Centre', _khi, '2023-11-01', 'O+', 'verified', _umer),
    (_umer_donor, _civil, 'Civil Hospital Karachi',       _khi, '2023-07-28', 'O+', 'verified', _umer),
    (_umer_donor, _akuh,  'Aga Khan University Hospital', _khi, '2023-04-12', 'O+', 'verified', _umer),
    (_umer_donor, null,   'Indus Hospital',               _khi, '2022-12-30', 'O+', 'verified', _umer);

  -- ── Blood requests (mix of sources and statuses) ──────────────────────────
  insert into public.blood_requests (patient_name, blood_group, units, urgency, status, source, hospital_id, hospital_name,
    city_id, contact_name, contact_phone, description, requester_id, approved_at, created_at)
  values ('Raza Ul Haq', 'O+', 3, 'critical', 'active', 'android', _akuh, 'Aga Khan University Hospital', _khi,
    'Dr. Imran Malik', '+92-21-34930051',
    'Patient is in ICU after a road accident. Immediate transfusion required.', _kamran, now() - interval '2 hours', now() - interval '2 hours')
  returning id into _r_raza;

  insert into public.blood_requests (patient_name, blood_group, units, urgency, status, source, hospital_id, hospital_name,
    city_id, contact_name, contact_phone, description, requester_id, approved_at, created_at)
  values ('Ayesha Siddiqui', 'B+', 2, 'urgent', 'active', 'android', _lnh, 'Liaquat National Hospital', _khi,
    'Kamran Siddiqui', '+92-333-1239876',
    'Thalassemia patient (age 9) needs her monthly transfusion within 24 hours.', _kamran, now() - interval '8 hours', now() - interval '8 hours')
  returning id into _r_ayesha;

  insert into public.blood_requests (patient_name, blood_group, units, urgency, status, source, hospital_id, hospital_name,
    city_id, contact_name, contact_phone, description, approved_at, created_at)
  values
    ('Ali Raza Naqvi', 'O-', 4, 'critical', 'active', 'website', _civil, 'Civil Hospital Karachi', _khi,
     'Naqvi Family', '+92-300-2468135', 'Critical condition post major surgery. O- required immediately.', now() - interval '5 hours', now() - interval '5 hours'),
    ('Zara Hussain', 'AB-', 1, 'normal', 'approved', 'website', _skmch, 'Shaukat Khanum Memorial Cancer Hospital', _lhe,
     'Blood Bank Desk', '+92-42-35905000', 'Chemotherapy patient with low hemoglobin.', now() - interval '30 hours', now() - interval '30 hours');

  -- awaiting admin review
  insert into public.blood_requests (patient_name, blood_group, units, urgency, status, source, hospital_name,
    city_id, contact_name, contact_phone, description, created_at)
  values
    ('Fatima Malik', 'A+', 2, 'normal', 'pending', 'website', 'South City Hospital', _khi,
     'Hassan Malik', '+92-321-5550192', 'Scheduled C-section; two units of A+ as backup.', now() - interval '20 minutes'),
    ('Saad Ahmed', 'A-', 2, 'urgent', 'pending', 'android', 'Pakistan Institute of Medical Sciences',
     (select id from public.cities where name = 'Islamabad'), 'Nadia Ahmed', '+92-51-9261170',
     'Open-heart surgery planned next week.', now() - interval '45 minutes');

  -- closed
  insert into public.blood_requests (patient_name, blood_group, units, urgency, status, source, hospital_id, hospital_name,
    city_id, contact_name, contact_phone, description, approved_at, fulfilled_at, closed_at, created_at)
  values ('Hamid Qureshi', 'O+', 1, 'urgent', 'fulfilled', 'website', null, 'Jinnah Postgraduate Medical Centre', _khi,
    'Ward 7 Nurse Station', '+92-21-99201300', 'Dialysis patient required one unit of O+.',
    now() - interval '3 days', now() - interval '2 days', now() - interval '2 days', now() - interval '3 days');

  -- ── Responses ──────────────────────────────────────────────────────────────
  insert into public.request_responses (request_id, donor_id, responder_id)
  select _r_raza, d.id, d.profile_id from public.donors d where d.profile_id in (_ahmed);
  insert into public.request_responses (request_id, donor_id, responder_id)
  values (_r_raza, _bilal, null);
end $$;
