-- ============================================================================
-- LifeLink Platform — 0002: core tables, constraints, indexes
-- ============================================================================

-- Reusable validation domains -----------------------------------------------
create domain public.phone_text as text
  check (value ~ '^\+?[0-9][0-9 ()\-]{6,22}$');

create domain public.person_name as text
  check (char_length(trim(value)) between 2 and 100);

-- ============================================================================
-- IDENTITY
-- ============================================================================

-- One row per auth user. Created automatically by trigger on auth.users.
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  full_name     public.person_name not null,
  email         extensions.citext not null,
  phone         public.phone_text,
  blood_group   text references public.blood_groups (code),
  account_type  public.account_type not null default 'both',
  city_id       integer references public.cities (id),
  area          text check (area is null or char_length(area) <= 120),
  date_of_birth date check (date_of_birth is null or date_of_birth between date '1900-01-01' and current_date),
  gender        public.gender,
  weight_kg     numeric(5,1) check (weight_kg is null or weight_kg between 20 and 300),
  avatar_path   text,
  is_verified   boolean not null default false,
  status        public.account_status not null default 'active',
  suspended_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint profiles_email_unique unique (email)
);
create index profiles_city_idx on public.profiles (city_id);
create index profiles_blood_group_idx on public.profiles (blood_group);

-- Privileged roles. Ordinary users have no rows here.
create table public.user_roles (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.app_role not null,
  granted_by uuid references public.profiles (id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);

create table public.user_addresses (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  label       text not null default 'Home' check (char_length(label) <= 40),
  line1       text not null check (char_length(line1) between 3 and 200),
  area        text check (area is null or char_length(area) <= 120),
  city_id     integer not null references public.cities (id),
  latitude    numeric(9,6) check (latitude between -90 and 90),
  longitude   numeric(9,6) check (longitude between -180 and 180),
  is_primary  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index user_addresses_user_idx on public.user_addresses (user_id);
create unique index user_addresses_one_primary on public.user_addresses (user_id) where is_primary;

-- Staff members allowed to manage a specific hospital's inventory.
-- (hospital_id FK added after hospitals is created)
create table public.hospital_staff (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  hospital_id uuid not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, hospital_id)
);

-- ============================================================================
-- DONORS
-- ============================================================================

-- Anonymous applications from the website "Become a Donor" form.
create table public.donor_applications (
  id           uuid primary key default gen_random_uuid(),
  full_name    public.person_name not null,
  email        extensions.citext not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone        public.phone_text not null,
  age          smallint not null check (age between 17 and 65),
  gender       public.gender not null,
  blood_group  text not null references public.blood_groups (code),
  city_id      integer not null references public.cities (id),
  status       public.application_status not null default 'pending',
  source       public.request_source not null default 'website',
  submitted_by uuid references public.profiles (id) on delete set null,
  reviewed_by  uuid references public.profiles (id) on delete set null,
  reviewed_at  timestamptz,
  review_note  text check (review_note is null or char_length(review_note) <= 500),
  donor_id     uuid,  -- FK added below (donors created after)
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index donor_applications_one_pending_per_email
  on public.donor_applications (email) where status = 'pending';
create index donor_applications_status_idx on public.donor_applications (status, created_at desc);

-- A donor either belongs to an account (profile_id) or is a website-approved
-- donor without an account (identity fields stored here). When that person
-- later signs up with the same email, the trigger links the rows (no duplicate).
create table public.donors (
  id             uuid primary key default gen_random_uuid(),
  profile_id     uuid unique references public.profiles (id) on delete set null,
  full_name      public.person_name,
  email          extensions.citext,
  phone          public.phone_text,
  age            smallint check (age is null or age between 17 and 65),
  gender         public.gender,
  blood_group    text not null references public.blood_groups (code),
  city_id        integer not null references public.cities (id),
  area           text check (area is null or char_length(area) <= 120),
  hours          text check (hours is null or char_length(hours) <= 40),
  about          text check (about is null or char_length(about) <= 500),
  is_active      boolean not null default true,
  is_verified    boolean not null default false,
  rating         numeric(2,1) check (rating is null or rating between 0 and 5),
  rating_count   integer not null default 0 check (rating_count >= 0),
  application_id uuid references public.donor_applications (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- unlinked donors must carry their own contact identity
  constraint donors_identity_required check (
    profile_id is not null or (full_name is not null and phone is not null)
  )
);
create unique index donors_email_unique on public.donors (email) where email is not null;
create index donors_search_idx on public.donors (blood_group, city_id) where is_active;

alter table public.donor_applications
  add constraint donor_applications_donor_fk foreign key (donor_id) references public.donors (id) on delete set null;

-- Current availability (1:1 with donors). History is captured by audit_logs.
create table public.donor_availability (
  donor_id   uuid primary key references public.donors (id) on delete cascade,
  status     public.availability_status not null default 'available',
  note       text check (note is null or char_length(note) <= 200),
  updated_by uuid references public.profiles (id) on delete set null,
  updated_at timestamptz not null default now()
);
create index donor_availability_status_idx on public.donor_availability (status);

-- ============================================================================
-- HOSPITALS
-- ============================================================================

create table public.hospitals (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (char_length(trim(name)) between 3 and 160),
  type           public.hospital_type not null,
  has_blood_bank boolean not null default false,
  city_id        integer not null references public.cities (id),
  address        text not null check (char_length(address) between 5 and 250),
  phone          public.phone_text,
  email          extensions.citext,
  latitude       numeric(9,6) check (latitude between -90 and 90),
  longitude      numeric(9,6) check (longitude between -180 and 180),
  open_24h       boolean not null default true,
  opening_hours  text check (opening_hours is null or char_length(opening_hours) <= 80),
  beds           integer check (beds is null or beds >= 0),
  rating         numeric(3,2) check (rating is null or rating between 0 and 5),
  reviews_count  integer not null default 0 check (reviews_count >= 0),
  about          text check (about is null or char_length(about) <= 1000),
  services       text[] not null default '{}',
  is_verified    boolean not null default false,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint hospitals_name_city_unique unique (name, city_id)
);
create index hospitals_city_idx on public.hospitals (city_id) where is_active;

alter table public.hospital_staff
  add constraint hospital_staff_hospital_fk foreign key (hospital_id) references public.hospitals (id) on delete cascade;

create table public.hospital_inventory (
  hospital_id uuid not null references public.hospitals (id) on delete cascade,
  blood_group text not null references public.blood_groups (code),
  units       integer not null default 0 check (units between 0 and 100000),
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now(),
  primary key (hospital_id, blood_group)
);

-- ============================================================================
-- BLOOD REQUESTS
-- ============================================================================

create sequence public.blood_request_ref_seq;

create table public.blood_requests (
  id              uuid primary key default gen_random_uuid(),
  reference_code  text not null unique
                  default ('BR-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.blood_request_ref_seq')::text, 6, '0')),
  patient_name    public.person_name not null,
  blood_group     text not null references public.blood_groups (code),
  units           smallint not null default 1 check (units between 1 and 10),
  urgency         public.request_urgency not null default 'normal',
  status          public.request_status not null default 'pending',
  source          public.request_source not null,
  hospital_id     uuid references public.hospitals (id) on delete set null,
  hospital_name   text not null check (char_length(trim(hospital_name)) between 2 and 160),
  hospital_address text check (hospital_address is null or char_length(hospital_address) <= 250),
  city_id         integer not null references public.cities (id),
  contact_name    public.person_name not null,
  contact_phone   public.phone_text not null,
  description     text check (description is null or char_length(description) <= 1000),
  needed_by       timestamptz,
  requester_id    uuid references public.profiles (id) on delete set null,
  approved_by     uuid references public.profiles (id) on delete set null,
  approved_at     timestamptz,
  status_reason   text check (status_reason is null or char_length(status_reason) <= 500),
  fulfilled_at    timestamptz,
  closed_at       timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index blood_requests_status_created_idx on public.blood_requests (status, created_at desc);
create index blood_requests_group_idx on public.blood_requests (blood_group);
create index blood_requests_city_idx on public.blood_requests (city_id);
create index blood_requests_requester_idx on public.blood_requests (requester_id);
create index blood_requests_hospital_idx on public.blood_requests (hospital_id);
create index blood_requests_open_urgent_idx on public.blood_requests (urgency, created_at desc)
  where status in ('approved', 'active');

create table public.request_status_history (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.blood_requests (id) on delete cascade,
  from_status public.request_status,
  to_status   public.request_status not null,
  changed_by  uuid references public.profiles (id) on delete set null,
  reason      text,
  changed_at  timestamptz not null default now()
);
create index request_status_history_request_idx on public.request_status_history (request_id, changed_at);

create table public.request_responses (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.blood_requests (id) on delete cascade,
  donor_id     uuid not null references public.donors (id) on delete cascade,
  responder_id uuid references public.profiles (id) on delete set null,
  status       public.response_status not null default 'responded',
  message      text check (message is null or char_length(message) <= 500),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint request_responses_one_per_donor unique (request_id, donor_id)
);
create index request_responses_donor_idx on public.request_responses (donor_id);

-- ============================================================================
-- DONATIONS
-- ============================================================================

create sequence public.donation_cert_seq;

create table public.donations (
  id             uuid primary key default gen_random_uuid(),
  donor_id       uuid not null references public.donors (id) on delete cascade,
  request_id     uuid references public.blood_requests (id) on delete set null,
  hospital_id    uuid references public.hospitals (id) on delete set null,
  hospital_name  text not null check (char_length(trim(hospital_name)) between 2 and 160),
  city_id        integer references public.cities (id),
  donated_on     date not null check (donated_on <= current_date and donated_on >= date '1990-01-01'),
  units          smallint not null default 1 check (units between 1 and 2),
  blood_group    text not null references public.blood_groups (code),
  status         public.donation_status not null default 'recorded',
  certificate_no text not null unique
                 default ('LL-' || to_char(now(), 'YY-MM') || '-' || lpad(nextval('public.donation_cert_seq')::text, 5, '0')),
  recorded_by    uuid references public.profiles (id) on delete set null,
  verified_by    uuid references public.profiles (id) on delete set null,
  verified_at    timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index donations_donor_idx on public.donations (donor_id, donated_on desc);
create unique index donations_one_per_request_donor on public.donations (request_id, donor_id) where request_id is not null;

create table public.user_badges (
  user_id   uuid not null references public.profiles (id) on delete cascade,
  badge_id  text not null references public.badges (id),
  earned_at timestamptz not null default now(),
  primary key (user_id, badge_id)
);

-- ============================================================================
-- COMMUNICATION
-- ============================================================================

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  type       public.notification_type not null,
  title      text not null check (char_length(title) <= 120),
  body       text not null check (char_length(body) <= 500),
  link       text check (link is null or link ~ '^/'),
  data       jsonb not null default '{}',
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;

create table public.notification_preferences (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  push_enabled      boolean not null default true,
  emergency_alerts  boolean not null default true,
  sms_alerts        boolean not null default true,
  email_updates     boolean not null default false,
  show_in_search    boolean not null default true,
  share_location    boolean not null default true,
  search_radius_km  smallint not null default 10 check (search_radius_km in (5, 10, 25, 50)),
  updated_at        timestamptz not null default now()
);

create table public.device_push_tokens (
  token      text primary key check (char_length(token) <= 300),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  platform   text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
create index device_push_tokens_user_idx on public.device_push_tokens (user_id);

-- Website "Contact Us" form.
create table public.contact_messages (
  id         uuid primary key default gen_random_uuid(),
  first_name public.person_name not null,
  last_name  text check (last_name is null or char_length(last_name) <= 100),
  email      extensions.citext not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone      text check (phone is null or phone ~ '^\+?[0-9][0-9 ()\-]{6,22}$'),
  message    text not null check (char_length(trim(message)) between 5 and 4000),
  read_at    timestamptz,
  read_by    uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index contact_messages_created_idx on public.contact_messages (created_at desc);

-- ============================================================================
-- ADMINISTRATION
-- ============================================================================

-- Row-level change log written by triggers on sensitive tables.
create table public.audit_logs (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  record_id   text not null,
  action      text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data    jsonb,
  new_data    jsonb,
  actor_id    uuid,
  created_at  timestamptz not null default now()
);
create index audit_logs_record_idx on public.audit_logs (table_name, record_id, created_at desc);
create index audit_logs_created_idx on public.audit_logs (created_at desc);

-- Human-readable admin actions written by admin RPCs.
create table public.admin_activity_logs (
  id          bigint generated always as identity primary key,
  admin_id    uuid references public.profiles (id) on delete set null,
  action      text not null,
  target_type text not null,
  target_id   text,
  details     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index admin_activity_logs_created_idx on public.admin_activity_logs (created_at desc);
create index admin_activity_logs_target_idx on public.admin_activity_logs (target_type, target_id);
