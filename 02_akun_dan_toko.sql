-- ============================================================================
--  Jalankan SETELAH kamu membuat 3 akun di
--  Supabase → Authentication → Users → Add user → Create new user
--  (centang "Auto Confirm User")
--
--     admin@gudang.local    password = PIN Admin Harian
--     gudang@gudang.local   password = PIN Gudang
--     kepala@gudang.local   password = PIN Kepala Admin
--
--  Password-nya nanti bisa diganti sendiri dari halaman Kepala Admin.
-- ============================================================================

insert into profiles (user_id, role, display_name)
select id, 'admin', 'Admin Harian' from auth.users where email = 'admin@gudang.local'
on conflict (user_id) do update set role = excluded.role;

insert into profiles (user_id, role, display_name)
select id, 'gudang', 'Gudang' from auth.users where email = 'gudang@gudang.local'
on conflict (user_id) do update set role = excluded.role;

insert into profiles (user_id, role, display_name)
select id, 'kepala', 'Kepala Admin' from auth.users where email = 'kepala@gudang.local'
on conflict (user_id) do update set role = excluded.role;

-- Toko. sender_names = tulisan "Pengirim" yang muncul di label.
insert into shops (shop_id, name, sender_names) values
  ('295742354', 'GOWES', array['GOWES','Gowes'])
on conflict (shop_id) do update
  set name = excluded.name, sender_names = excluded.sender_names;

-- Cek hasilnya
select p.role, u.email from profiles p join auth.users u on u.id = p.user_id order by p.role;
select * from shops;
