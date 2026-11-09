-- ============================================================================
-- Reference data: partner hospitals + starting inventory.
-- Safe to load into production AFTER you review the figures (idempotent).
-- Inventory numbers are illustrative — hospital staff should update them.
-- ============================================================================

with h(name, type, has_bank, city, address, phone, rating, reviews, open24, beds, about, services, verified) as (values
  ('Shaukat Khanum Memorial Cancer Hospital', 'private', true, 'Lahore', '7-A Block R-3, M.A. Johar Town, Lahore', '+92-42-35905000', 4.95, 5800, true, 195,
   'Cancer hospital providing free treatment to deserving patients, with platelet apheresis services.', '{Blood Bank,Platelet Apheresis,Oncology,ICU,Emergency}', true),
  ('Aga Khan University Hospital', 'private', true, 'Karachi', 'Stadium Road, Karachi 74800', '+92-21-34930051', 4.90, 3420, true, 700,
   'JCI-accredited teaching hospital with component separation and 24/7 crossmatching.', '{Blood Bank,Trauma Center,Cardiology,ICU,Emergency}', true),
  ('Liaquat National Hospital', 'private', true, 'Karachi', 'National Stadium Road, Karachi 74800', '+92-21-34412000', 4.70, 2150, true, 700,
   'Tertiary care hospital with a thalassemia day-care unit and in-house blood bank.', '{Blood Bank,Thalassemia Care,Surgery,Emergency}', true),
  ('Civil Hospital Karachi', 'public', true, 'Karachi', 'Baba-e-Urdu Road, Saddar, Karachi', '+92-21-99215740', 4.10, 1890, true, 1900,
   'One of the largest public hospitals in Pakistan with a high-volume blood bank.', '{Blood Bank,Burns Center,Trauma,Emergency}', true),
  ('Jinnah Postgraduate Medical Centre', 'public', true, 'Karachi', 'Rafiqui Shaheed Road, Karachi', '+92-21-99201300', 4.20, 1320, true, 1600,
   'Federal teaching hospital with a regional blood transfusion centre.', '{Blood Bank,Cardiac Surgery,Dialysis,Emergency}', true),
  ('Pakistan Institute of Medical Sciences', 'semi_government', true, 'Islamabad', 'Ibn-e-Sina Road, G-8/3, Islamabad', '+92-51-9261170', 4.30, 2740, true, 1100,
   'Leading federal hospital of the capital with a modern blood transfusion service.', '{Blood Bank,Pediatrics,Nephrology,Emergency}', true),
  ('Isra University Hospital', 'private', true, 'Hyderabad', 'Hala Road, Hala Naka, Hyderabad', '+92-22-2030161', 4.40, 610, false, 450,
   'Teaching hospital serving Hyderabad and interior Sindh.', '{Blood Bank,Gynecology,Orthopedics,OPD}', false),
  ('Holy Family Hospital', 'public', true, 'Rawalpindi', 'Satellite Town, Rawalpindi', '+92-51-9290321', 4.00, 980, true, 1000,
   'Teaching hospital of Rawalpindi Medical University with a regional blood bank.', '{Blood Bank,Maternity,Emergency}', true)
)
insert into public.hospitals (name, type, has_blood_bank, city_id, address, phone, rating, reviews_count, open_24h,
                              opening_hours, beds, about, services, is_verified)
select h.name, h.type::public.hospital_type, h.has_bank, c.id, h.address, h.phone, h.rating, h.reviews, h.open24,
       case when h.open24 then null else '8 AM – 8 PM' end, h.beds, h.about, h.services::text[], h.verified
from h join public.cities c on c.name = h.city
on conflict (name, city_id) do nothing;

with inv(hospital, groups) as (values
  ('Shaukat Khanum Memorial Cancer Hospital',  '{"A+":24,"A-":11,"B+":30,"B-":6,"AB+":12,"AB-":2,"O+":35,"O-":8}'::jsonb),
  ('Aga Khan University Hospital',             '{"A+":28,"A-":7,"B+":26,"B-":3,"AB+":14,"AB-":2,"O+":40,"O-":9}'),
  ('Liaquat National Hospital',                '{"A+":18,"A-":5,"B+":9,"B-":4,"AB+":10,"AB-":1,"O+":22,"O-":6}'),
  ('Civil Hospital Karachi',                   '{"A+":14,"A-":2,"B+":16,"B-":2,"AB+":6,"AB-":0,"O+":19,"O-":1}'),
  ('Jinnah Postgraduate Medical Centre',       '{"A+":20,"A-":6,"B+":21,"B-":5,"AB+":9,"AB-":3,"O+":25,"O-":4}'),
  ('Pakistan Institute of Medical Sciences',   '{"A+":22,"A-":4,"B+":27,"B-":7,"AB+":11,"AB-":4,"O+":31,"O-":5}'),
  ('Isra University Hospital',                 '{"A+":12,"A-":3,"B+":15,"B-":2,"AB+":5,"AB-":1,"O+":17,"O-":3}'),
  ('Holy Family Hospital',                     '{"A+":16,"A-":3,"B+":19,"B-":2,"AB+":7,"AB-":2,"O+":21,"O-":3}')
)
insert into public.hospital_inventory (hospital_id, blood_group, units)
select hp.id, kv.key, kv.value::int
from inv
join public.hospitals hp on hp.name = inv.hospital
cross join lateral jsonb_each_text(inv.groups) kv
on conflict (hospital_id, blood_group) do nothing;
