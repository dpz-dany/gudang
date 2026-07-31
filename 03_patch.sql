-- ============================================================================
--  PATCH v3  —  jalankan SETELAH 01_schema.sql dan 02_akun_dan_toko.sql
--  Aman dijalankan berulang kali.
--
--  Isi:
--   1. Dukungan TikTok / Tokopedia (platform + pencocokan toko lewat NickName)
--   2. Pusat notifikasi untuk Kepala Admin
--   3. "Lanjut Kirim" — barang tetap keluar walau ada SKU yang belum cocok
--   4. Gudang boleh menambah barang pada sebuah pesanan
--   5. Retur COD tiga tahap: Admin ajukan → Kepala setuju → Gudang terima
--   6. Sesi opname untuk Gudang (Kepala yang menyetujui selisihnya)
--   7. Kiriman LCL sebagai rujukan barang masuk
--   8. Tiga perbaikan keamanan
-- ============================================================================

-- ============================================================================
-- 1. PLATFORM
-- ============================================================================

alter table shops  add column if not exists platform text default 'shopee';
alter table orders add column if not exists platform text default 'shopee';

-- NickName TikTok cukup ditaruh di sender_names; shop_from_sender sudah
-- mencocokkan nama toko DAN semua alias di kolom itu.

-- ============================================================================
-- 2. NOTIFIKASI
-- ============================================================================

create table if not exists notifikasi (
  notif_id     bigserial primary key,
  jenis        text not null,      -- sku_tidak_dikenal | kirim_paksa | gudang_tambah
                                   -- retur_diajukan | retur_diterima | opname_diajukan
                                   -- koreksi_tinggi | sinkron_ditolak | pin_diganti
  tingkat      text not null default 'info' check (tingkat in ('info','perhatian','bahaya')),
  judul        text not null,
  ref          text,
  shop_id      text,
  isi          jsonb,
  status       text not null default 'baru' check (status in ('baru','dibaca','selesai')),
  dibuat_oleh  text,
  dibuat_pada  timestamptz default now(),
  ditutup_oleh text,
  ditutup_pada timestamptz,
  catatan      text
);
create index if not exists notif_status_idx on notifikasi (status, dibuat_pada desc);
create index if not exists notif_jenis_idx  on notifikasi (jenis);

create or replace function notif(
  p_jenis text, p_tingkat text, p_judul text,
  p_ref text default null, p_shop text default null,
  p_isi jsonb default null, p_oleh text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare id bigint;
begin
  insert into notifikasi (jenis, tingkat, judul, ref, shop_id, isi, dibuat_oleh)
  values (p_jenis, p_tingkat, p_judul, p_ref, p_shop, p_isi, p_oleh)
  returning notif_id into id;
  return id;
end $$;

create or replace function tutup_notif(p_id bigint, p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  update notifikasi set status = 'selesai', ditutup_pada = now(),
         ditutup_oleh = coalesce((select display_name from profiles where user_id = auth.uid()), 'kepala'),
         catatan = coalesce(p_catatan, catatan)
   where notif_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ============================================================================
-- 3. PERANGKAT (perbaikan keamanan #1)
--    PIN itu rahasia bersama. Supaya tetap terlacak, setiap pemindaian
--    mencatat ID perangkat. Kalau "kunci perangkat" dinyalakan, hanya
--    perangkat terdaftar yang boleh memindai — dipaksa di server.
-- ============================================================================

create table if not exists perangkat (
  device_id   text primary key,
  nama        text,
  peran       text,
  disetujui   boolean not null default false,
  terakhir    timestamptz,
  dibuat_pada timestamptz default now()
);

create table if not exists pengaturan (
  kunci text primary key,
  nilai text
);
insert into pengaturan (kunci, nilai) values ('kunci_perangkat', 'off')
on conflict (kunci) do nothing;

create or replace function catat_perangkat(p_device text, p_peran text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_device is null or p_device = '' then return; end if;
  insert into perangkat (device_id, peran, terakhir) values (p_device, p_peran, now())
  on conflict (device_id) do update set terakhir = now(), peran = excluded.peran;
end $$;

create or replace function perangkat_boleh(p_device text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare k text;
begin
  select nilai into k from pengaturan where kunci = 'kunci_perangkat';
  if coalesce(k,'off') <> 'on' then return true; end if;
  return exists (select 1 from perangkat where device_id = p_device and disetujui);
end $$;

alter table stock_movements add column if not exists device_id text;

-- ============================================================================
-- 4. PESANAN: kolom baru untuk "kirim paksa" dan barang tambahan gudang
-- ============================================================================

alter table orders      add column if not exists dipaksa      boolean not null default false;
alter table orders      add column if not exists alasan_paksa text;
alter table order_items add column if not exists ditambah_gudang boolean not null default false;
alter table order_items add column if not exists ditambah_oleh   text;
alter table order_items add column if not exists ditambah_pada   timestamptz;
-- Barang yang ditambahkan Gudang stoknya dipotong SAAT ITU JUGA (barangnya
-- memang sedang dimasukkan ke dus). Tanda ini mencegah scan_out memotongnya
-- untuk kedua kalinya.
alter table order_items add column if not exists sudah_potong boolean not null default false;

-- ============================================================================
-- 5. LANJUT KIRIM
--    Barang sudah terlanjur dikirim. Baris yang cocok tetap dipotong,
--    baris yang belum cocok dicatat sebagai utang data untuk Kepala Admin.
-- ============================================================================

create or replace function kirim_paksa(
  p_scan text, p_operator text default null, p_alasan text default null,
  p_client_id text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o orders%rowtype; it record; bal integer;
  baris jsonb := '[]'::jsonb; belum jsonb := '[]'::jsonb;
  key text := norm(p_scan);
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if not perangkat_boleh(p_device) then
    return jsonb_build_object('ok', false, 'code', 'perangkat_belum_disetujui');
  end if;
  perform catat_perangkat(p_device, my_role());

  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id like p_client_id || ':%') then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true, 'code', 'sudah_tersinkron');
  end if;

  select * into o from orders where norm(order_sn) = key or norm(tracking_no) = key limit 1;
  if not found then return jsonb_build_object('ok', false, 'code', 'pesanan_tidak_ada', 'scan', p_scan); end if;
  if o.status = 'packed' then
    return jsonb_build_object('ok', false, 'code', 'sudah_dipindai',
      'order_sn', o.order_sn, 'packed_at', o.packed_at, 'packed_by', o.packed_by);
  end if;

  for it in select * from order_items where order_sn = o.order_sn and not sudah_potong loop
    if it.variation_id is null then
      belum := belum || jsonb_build_object('sku', it.sku_label, 'variasi', it.variation_name,
                'produk', it.product_name, 'qty', it.qty_final);
    else
      update variations set stock_on_hand = stock_on_hand - it.qty_final, updated_at = now()
       where variation_id = it.variation_id returning stock_on_hand into bal;
      insert into stock_movements (shop_id, variation_id, sku, delta, balance_after, reason,
                                   ref, note, operator, client_scan_id, device_id)
      values (o.shop_id, it.variation_id,
              (select sku from variations where variation_id = it.variation_id),
              -it.qty_final, bal, 'keluar', o.order_sn, 'lanjut kirim', p_operator,
              case when p_client_id is null then null else p_client_id || ':' || it.id end, p_device);
      baris := baris || jsonb_build_object('sku', (select sku from variations where variation_id = it.variation_id),
                'variasi', it.variation_name, 'qty', it.qty_final, 'sisa', bal, 'minus', (bal < 0));
    end if;
  end loop;

  update orders set status = 'packed', packed_at = now(), packed_by = p_operator,
                    dipaksa = true, alasan_paksa = p_alasan
   where order_sn = o.order_sn;

  perform notif('kirim_paksa',
    case when jsonb_array_length(belum) > 0 then 'bahaya' else 'perhatian' end,
    'Pesanan ' || o.order_sn || ' dihijaukan paksa tanpa pemindaian penuh',
    o.order_sn, o.shop_id,
    jsonb_build_object('alasan', p_alasan, 'belum_terpotong', belum,
                       'terpotong', baris, 'petugas', p_operator, 'perangkat', p_device),
    p_operator);

  return jsonb_build_object('ok', true, 'dipaksa', true, 'order_sn', o.order_sn,
    'tracking_no', o.tracking_no, 'buyer_name', o.buyer_name,
    'baris', baris, 'belum', belum);
end $$;

-- ============================================================================
-- 6. GUDANG MENAMBAH BARANG PADA SEBUAH PESANAN
-- ============================================================================

create or replace function gudang_tambah_barang(
  p_order_sn text, p_variation_id text, p_qty integer,
  p_operator text default null, p_catatan text default null,
  p_client_id text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o orders%rowtype; bal integer; sk text; nm text; vn text; baris_id bigint;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if not (p_qty > 0) then return jsonb_build_object('ok', false, 'code', 'qty_tidak_sah'); end if;
  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id = p_client_id) then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true);
  end if;

  select * into o from orders where norm(order_sn) = norm(p_order_sn) limit 1;
  if not found then return jsonb_build_object('ok', false, 'code', 'pesanan_tidak_ada'); end if;

  select v.sku, p.product_name, v.variation_name into sk, nm, vn
    from variations v left join products p on p.product_id = v.product_id
   where v.variation_id = p_variation_id;
  if sk is null then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;

  insert into order_items (order_sn, line_no, sku_label, variation_name, product_name,
                           qty_label, variation_id, resolve_method,
                           ditambah_gudang, ditambah_oleh, ditambah_pada, sudah_potong)
  values (o.order_sn,
          coalesce((select max(line_no) from order_items where order_sn = o.order_sn), 0) + 1,
          sk, vn, nm, p_qty, p_variation_id, 'tambahan gudang', true, p_operator, now(), true)
  returning id into baris_id;

  update variations set stock_on_hand = stock_on_hand - p_qty, updated_at = now()
   where variation_id = p_variation_id returning stock_on_hand into bal;

  insert into stock_movements (shop_id, variation_id, sku, delta, balance_after, reason,
                               ref, note, operator, client_scan_id, device_id)
  values (o.shop_id, p_variation_id, sk, -p_qty, bal, 'keluar_tambahan', o.order_sn,
          'ditambahkan Gudang' || coalesce(' · ' || p_catatan, ''), p_operator, p_client_id, p_device);

  perform notif('gudang_tambah', 'perhatian',
    'Gudang menambah ' || p_qty || ' × ' || sk || ' pada pesanan ' || o.order_sn,
    o.order_sn, o.shop_id,
    jsonb_build_object('sku', sk, 'produk', nm, 'variasi', vn, 'qty', p_qty,
                       'catatan', p_catatan, 'petugas', p_operator, 'sisa', bal),
    p_operator);

  return jsonb_build_object('ok', true, 'sku', sk, 'qty', p_qty, 'sisa', bal,
                            'minus', (bal < 0), 'baris_id', baris_id);
end $$;

-- ============================================================================
-- 7. RETUR COD — tiga tahap
--    draft (Admin) → disetujui (Kepala) → diterima (Gudang, stok naik)
-- ============================================================================

create table if not exists retur (
  retur_id      uuid primary key default gen_random_uuid(),
  shop_id       text references shops(shop_id),
  order_sn      text not null,
  tracking_no   text,
  alasan        text,
  status        text not null default 'draft'
                  check (status in ('draft','disetujui','diterima','ditolak')),
  dibuat_oleh   text, dibuat_pada   timestamptz default now(),
  disetujui_oleh text, disetujui_pada timestamptz,
  diterima_oleh text, diterima_pada timestamptz,
  ditolak_oleh  text, ditolak_pada  timestamptz, alasan_tolak text,
  catatan       text
);
create index if not exists retur_status_idx on retur (status, dibuat_pada desc);
create index if not exists retur_order_idx  on retur (norm(order_sn));

create table if not exists retur_items (
  id           bigserial primary key,
  retur_id     uuid references retur(retur_id) on delete cascade,
  sku_input    text not null,
  qty          integer not null check (qty > 0),
  variation_id text references variations(variation_id) on delete set null,
  catatan      text
);
create index if not exists retur_items_idx on retur_items (retur_id);

-- Admin Harian mengajukan
create or replace function retur_ajukan(
  p_shop text, p_order_sn text, p_tracking text, p_alasan text,
  p_items jsonb, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare id uuid; it jsonb; v text; m text; belum jsonb := '[]'::jsonb; n integer := 0;
begin
  if my_role() not in ('admin','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if coalesce(trim(p_order_sn),'') = '' then
    return jsonb_build_object('ok', false, 'code', 'nomor_pesanan_kosong');
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'code', 'tidak_ada_barang');
  end if;

  insert into retur (shop_id, order_sn, tracking_no, alasan, dibuat_oleh)
  values (p_shop, trim(p_order_sn), nullif(trim(coalesce(p_tracking,'')),''), p_alasan, p_operator)
  returning retur_id into id;

  for it in select * from jsonb_array_elements(p_items) loop
    select r.variation_id, r.method into v, m
      from resolve_variation(p_shop, it->>'sku', it->>'variasi', it->>'produk') r;
    insert into retur_items (retur_id, sku_input, qty, variation_id, catatan)
    values (id, it->>'sku', greatest(1, coalesce((it->>'qty')::int, 1)), v, it->>'catatan');
    if v is null then
      belum := belum || jsonb_build_object('sku', it->>'sku', 'sebab', m);
    else n := n + 1; end if;
  end loop;

  perform notif('retur_diajukan', 'perhatian',
    'Retur diajukan untuk pesanan ' || trim(p_order_sn),
    trim(p_order_sn), p_shop,
    jsonb_build_object('retur_id', id, 'alasan', p_alasan, 'cocok', n,
                       'belum_cocok', belum, 'oleh', p_operator),
    p_operator);

  return jsonb_build_object('ok', true, 'retur_id', id, 'cocok', n, 'belum_cocok', belum);
end $$;

-- Kepala Admin menyetujui / menolak
create or replace function retur_setujui(p_retur uuid, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r retur%rowtype; n integer;
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  select * into r from retur where retur_id = p_retur;
  if not found then return jsonb_build_object('ok', false, 'code', 'tidak_ada'); end if;
  if r.status <> 'draft' then return jsonb_build_object('ok', false, 'code', 'status_' || r.status); end if;

  select count(*) into n from retur_items where retur_id = p_retur and variation_id is null;
  if n > 0 then
    return jsonb_build_object('ok', false, 'code', 'ada_sku_belum_cocok', 'jumlah', n);
  end if;

  update retur set status = 'disetujui', disetujui_oleh = p_operator, disetujui_pada = now()
   where retur_id = p_retur;
  perform notif('retur_disetujui', 'info',
    'Retur ' || r.order_sn || ' disetujui — menunggu Gudang menerima barang',
    r.order_sn, r.shop_id, jsonb_build_object('retur_id', p_retur), p_operator);
  return jsonb_build_object('ok', true);
end $$;

create or replace function retur_tolak(p_retur uuid, p_alasan text, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  update retur set status = 'ditolak', ditolak_oleh = p_operator, ditolak_pada = now(),
                   alasan_tolak = p_alasan
   where retur_id = p_retur and status = 'draft';
  if not found then return jsonb_build_object('ok', false, 'code', 'tidak_bisa_ditolak'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Gudang menerima barang fisik → stok baru naik di sini
create or replace function retur_terima(
  p_retur uuid, p_operator text default null,
  p_client_id text default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r retur%rowtype; it record; bal integer; baris jsonb := '[]'::jsonb;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id like p_client_id || ':%') then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true);
  end if;

  select * into r from retur where retur_id = p_retur;
  if not found then return jsonb_build_object('ok', false, 'code', 'tidak_ada'); end if;
  if r.status <> 'disetujui' then
    return jsonb_build_object('ok', false, 'code', 'belum_disetujui', 'status', r.status);
  end if;

  for it in select * from retur_items where retur_id = p_retur loop
    update variations set stock_on_hand = stock_on_hand + it.qty, updated_at = now()
     where variation_id = it.variation_id returning stock_on_hand into bal;
    insert into stock_movements (shop_id, variation_id, sku, delta, balance_after, reason,
                                 ref, note, operator, client_scan_id, device_id)
    values (r.shop_id, it.variation_id,
            (select sku from variations where variation_id = it.variation_id),
            it.qty, bal, 'retur', r.order_sn,
            'retur COD · disetujui ' || coalesce(r.disetujui_oleh,'?'), p_operator,
            case when p_client_id is null then null else p_client_id || ':' || it.id end, p_device);
    baris := baris || jsonb_build_object('sku', it.sku_input, 'qty', it.qty, 'sisa', bal);
  end loop;

  update retur set status = 'diterima', diterima_oleh = p_operator, diterima_pada = now()
   where retur_id = p_retur;

  perform notif('retur_diterima', 'info',
    'Barang retur pesanan ' || r.order_sn || ' masuk gudang',
    r.order_sn, r.shop_id,
    jsonb_build_object('retur_id', p_retur, 'baris', baris, 'oleh', p_operator), p_operator);

  return jsonb_build_object('ok', true, 'baris', baris);
end $$;

-- ============================================================================
-- 8. SESI OPNAME  (Gudang menghitung · Kepala menyetujui selisih)
-- ============================================================================

create table if not exists opname_sesi (
  sesi_id       uuid primary key default gen_random_uuid(),
  shop_id       text references shops(shop_id),
  judul         text,
  status        text not null default 'berjalan'
                  check (status in ('berjalan','diajukan','disetujui','ditolak')),
  dibuat_oleh   text, dibuat_pada    timestamptz default now(),
  diajukan_pada timestamptz,
  disetujui_oleh text, disetujui_pada timestamptz,
  catatan       text
);

create table if not exists opname_baris (
  id           bigserial primary key,
  sesi_id      uuid references opname_sesi(sesi_id) on delete cascade,
  variation_id text references variations(variation_id) on delete cascade,
  stok_sistem  integer,
  stok_hitung  integer,
  selisih      integer generated always as (stok_hitung - stok_sistem) stored,
  catatan      text,
  unique (sesi_id, variation_id)
);

create or replace function opname_simpan(
  p_sesi uuid, p_variation_id text, p_hitung integer, p_catatan text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sis integer; st text;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  select status into st from opname_sesi where sesi_id = p_sesi;
  if st is null then return jsonb_build_object('ok', false, 'code', 'sesi_tidak_ada'); end if;
  if st <> 'berjalan' then return jsonb_build_object('ok', false, 'code', 'sesi_terkunci'); end if;

  select stock_on_hand into sis from variations where variation_id = p_variation_id;
  insert into opname_baris (sesi_id, variation_id, stok_sistem, stok_hitung, catatan)
  values (p_sesi, p_variation_id, sis, p_hitung, p_catatan)
  on conflict (sesi_id, variation_id) do update
    set stok_hitung = excluded.stok_hitung, stok_sistem = excluded.stok_sistem,
        catatan = excluded.catatan;
  return jsonb_build_object('ok', true, 'sistem', sis, 'selisih', p_hitung - sis);
end $$;

create or replace function opname_ajukan(p_sesi uuid, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n integer; ns integer; s opname_sesi%rowtype;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  select * into s from opname_sesi where sesi_id = p_sesi;
  if s.status <> 'berjalan' then return jsonb_build_object('ok', false, 'code', 'sesi_terkunci'); end if;

  select count(*), count(*) filter (where selisih <> 0) into n, ns
    from opname_baris where sesi_id = p_sesi;
  if n = 0 then return jsonb_build_object('ok', false, 'code', 'belum_ada_hitungan'); end if;

  update opname_sesi set status = 'diajukan', diajukan_pada = now() where sesi_id = p_sesi;
  perform notif('opname_diajukan', case when ns > 0 then 'perhatian' else 'info' end,
    'Sesi opname "' || coalesce(s.judul,'tanpa judul') || '" diajukan — ' || ns || ' selisih dari ' || n || ' SKU',
    p_sesi::text, s.shop_id,
    jsonb_build_object('sesi_id', p_sesi, 'baris', n, 'selisih', ns, 'oleh', p_operator), p_operator);
  return jsonb_build_object('ok', true, 'baris', n, 'selisih', ns);
end $$;

create or replace function opname_setujui(p_sesi uuid, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b record; bal integer; n integer := 0; s opname_sesi%rowtype;
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  select * into s from opname_sesi where sesi_id = p_sesi;
  if s.status <> 'diajukan' then return jsonb_build_object('ok', false, 'code', 'belum_diajukan'); end if;

  for b in select * from opname_baris where sesi_id = p_sesi and selisih <> 0 loop
    update variations set stock_on_hand = b.stok_hitung, updated_at = now()
     where variation_id = b.variation_id returning stock_on_hand into bal;
    insert into stock_movements (shop_id, variation_id, sku, delta, balance_after,
                                 reason, ref, note, operator)
    values (s.shop_id, b.variation_id,
            (select sku from variations where variation_id = b.variation_id),
            b.selisih, bal, 'opname', p_sesi::text,
            'hitung fisik ' || b.stok_hitung || ' (sistem ' || b.stok_sistem || ')', p_operator);
    n := n + 1;
  end loop;

  update opname_sesi set status = 'disetujui', disetujui_oleh = p_operator, disetujui_pada = now()
   where sesi_id = p_sesi;
  return jsonb_build_object('ok', true, 'disesuaikan', n);
end $$;

-- ============================================================================
-- 9. KIRIMAN LCL
--    Alur: Kepala membuat kiriman + daftar barang yang DIHARAPKAN.
--    Barang datang bertahap; setiap penerimaan menunjuk ke kiriman itu.
--    v_lcl_progres membandingkan diharapkan vs sudah diterima.
-- ============================================================================

create table if not exists lcl (
  lcl_id      uuid primary key default gen_random_uuid(),
  ref         text unique not null,       -- mis. LCL-2026-08-A
  pemasok     text,
  invoice_no  text,
  eta         date,
  status      text not null default 'jalan' check (status in ('jalan','tiba','selesai','batal')),
  catatan     text,
  dibuat_oleh text, dibuat_pada timestamptz default now()
);

create table if not exists lcl_items (
  id           bigserial primary key,
  lcl_id       uuid references lcl(lcl_id) on delete cascade,
  variation_id text references variations(variation_id) on delete cascade,
  qty_harap    integer not null check (qty_harap > 0),
  unique (lcl_id, variation_id)
);

alter table stock_movements add column if not exists lcl_id uuid references lcl(lcl_id) on delete set null;
create index if not exists mv_lcl_idx on stock_movements (lcl_id);

create or replace view v_lcl_progres as
select l.lcl_id, l.ref, l.pemasok, l.eta, l.status,
       li.variation_id, v.sku, p.product_name, v.variation_name,
       li.qty_harap,
       coalesce((select sum(m.delta) from stock_movements m
                  where m.lcl_id = l.lcl_id and m.variation_id = li.variation_id
                    and m.delta > 0), 0) as qty_datang
from lcl l
join lcl_items li on li.lcl_id = l.lcl_id
join variations v on v.variation_id = li.variation_id
left join products p on p.product_id = v.product_id;
alter view v_lcl_progres set (security_invoker = on);

-- ============================================================================
-- 10. stock_in versi baru: menerima LCL + ID perangkat
-- ============================================================================

create or replace function stock_in(
  p_variation_id text, p_qty integer, p_reason text default 'masuk',
  p_note text default null, p_ref text default null,
  p_operator text default null, p_client_id text default null,
  p_lcl_id uuid default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare bal integer; prev integer; d integer; sh text; sk text; lref text;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  -- opname sekarang lewat sesi opname, bukan lewat sini
  if p_reason = 'opname' and not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'opname_hanya_kepala');
  end if;
  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id = p_client_id) then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true);
  end if;
  perform catat_perangkat(p_device, my_role());

  select shop_id, sku, stock_on_hand into sh, sk, prev
    from variations where variation_id = p_variation_id;
  if sk is null then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;

  if p_lcl_id is not null then
    select ref into lref from lcl where lcl_id = p_lcl_id;
    if lref is null then return jsonb_build_object('ok', false, 'code', 'lcl_tidak_ada'); end if;
  end if;

  if p_reason = 'opname' then
    d := p_qty - prev;
    update variations set stock_on_hand = p_qty, updated_at = now()
     where variation_id = p_variation_id returning stock_on_hand into bal;
  else
    d := p_qty;
    update variations set stock_on_hand = stock_on_hand + p_qty, updated_at = now()
     where variation_id = p_variation_id returning stock_on_hand into bal;
  end if;

  insert into stock_movements (shop_id, variation_id, sku, delta, balance_after,
                               reason, ref, note, operator, client_scan_id, lcl_id, device_id)
  values (sh, p_variation_id, sk, d, bal, p_reason, coalesce(lref, p_ref),
          case when p_reason = 'opname'
               then coalesce(p_note || ' · ','') || 'hitung fisik ' || p_qty || ' (sistem ' || prev || ')'
               else p_note end,
          p_operator, p_client_id, p_lcl_id, p_device);

  return jsonb_build_object('ok', true, 'variation_id', p_variation_id, 'sku', sk,
                            'sisa', bal, 'lcl', lref);
end $$;

-- ============================================================================
-- 11. scan_out versi baru: catat perangkat + kunci perangkat + notifikasi
--     saat ada SKU yang belum cocok
-- ============================================================================

create or replace function scan_out(
  p_scan text, p_operator text default null, p_client_id text default null,
  p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o orders%rowtype; it record; bal integer;
  belum jsonb := '[]'::jsonb; baris jsonb := '[]'::jsonb;
  key text := norm(p_scan);
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if key = '' then return jsonb_build_object('ok', false, 'code', 'kosong'); end if;
  if not perangkat_boleh(p_device) then
    return jsonb_build_object('ok', false, 'code', 'perangkat_belum_disetujui', 'device', p_device);
  end if;
  perform catat_perangkat(p_device, my_role());

  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id like p_client_id || ':%') then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true, 'code', 'sudah_tersinkron');
  end if;

  select * into o from orders where norm(order_sn) = key or norm(tracking_no) = key limit 1;
  if not found then return jsonb_build_object('ok', false, 'code', 'pesanan_tidak_ada', 'scan', p_scan); end if;
  if o.status = 'packed' then
    return jsonb_build_object('ok', false, 'code', 'sudah_dipindai',
      'order_sn', o.order_sn, 'packed_at', o.packed_at, 'packed_by', o.packed_by,
      'dipaksa', o.dipaksa);
  end if;
  if o.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'code', 'dibatalkan', 'order_sn', o.order_sn);
  end if;
  if o.batch_id is not null and not exists (
       select 1 from upload_batches b where b.batch_id = o.batch_id and b.status = 'confirmed') then
    return jsonb_build_object('ok', false, 'code', 'batch_belum_dikonfirmasi', 'order_sn', o.order_sn);
  end if;

  for it in select * from order_items where order_sn = o.order_sn and not sudah_potong loop
    if it.variation_id is null then
      belum := belum || jsonb_build_object('sku', it.sku_label, 'variasi', it.variation_name,
                 'produk', it.product_name, 'qty', it.qty_final, 'sebab', coalesce(it.resolve_method,'?'));
    end if;
  end loop;

  if jsonb_array_length(belum) > 0 then
    -- satu notifikasi per pesanan, jangan menumpuk kalau dipindai berulang
    if not exists (select 1 from notifikasi
                    where jenis = 'sku_tidak_dikenal' and ref = o.order_sn and status <> 'selesai') then
      perform notif('sku_tidak_dikenal', 'bahaya',
        'Pesanan ' || o.order_sn || ' ditolak scanner — ' || jsonb_array_length(belum) || ' barang belum punya SKU cocok',
        o.order_sn, o.shop_id,
        jsonb_build_object('belum', belum, 'petugas', p_operator), p_operator);
    end if;
    return jsonb_build_object('ok', false, 'code', 'sku_belum_cocok',
      'order_sn', o.order_sn, 'belum', belum, 'boleh_paksa', true);
  end if;

  -- baris tambahan dari Gudang sudah dipotong saat ditambahkan: tampilkan saja
  for it in select oi.*, v.sku as sku_asli from order_items oi
              join variations v on v.variation_id = oi.variation_id
             where oi.order_sn = o.order_sn and oi.sudah_potong loop
    baris := baris || jsonb_build_object('sku', it.sku_asli, 'variation_id', it.variation_id,
      'variasi', it.variation_name, 'produk', it.product_name, 'qty', it.qty_final,
      'qty_fix', it.qty_fix, 'tambahan', true, 'sudah_potong', true,
      'sisa', (select stock_on_hand from variations where variation_id = it.variation_id),
      'minus', (select stock_on_hand < 0 from variations where variation_id = it.variation_id),
      'gambar', (select coalesce(v.image_url, p.image_url) from variations v
                   left join products p on p.product_id = v.product_id
                  where v.variation_id = it.variation_id));
  end loop;

  for it in select * from order_items where order_sn = o.order_sn and not sudah_potong loop
    update variations set stock_on_hand = stock_on_hand - it.qty_final, updated_at = now()
     where variation_id = it.variation_id returning stock_on_hand into bal;
    insert into stock_movements (shop_id, variation_id, sku, delta, balance_after,
                                 reason, ref, operator, client_scan_id, device_id)
    values (o.shop_id, it.variation_id,
            (select sku from variations where variation_id = it.variation_id),
            -it.qty_final, bal,
            case when it.ditambah_gudang then 'keluar_tambahan' else 'keluar' end,
            o.order_sn, p_operator,
            case when p_client_id is null then null else p_client_id || ':' || it.id end, p_device);

    baris := baris || jsonb_build_object(
      'sku', (select sku from variations where variation_id = it.variation_id),
      'variation_id', it.variation_id, 'variasi', it.variation_name, 'produk', it.product_name,
      'qty', it.qty_final, 'qty_fix', it.qty_fix, 'tambahan', it.ditambah_gudang,
      'sisa', bal, 'minus', (bal < 0),
      'gambar', (select coalesce(v.image_url, p.image_url) from variations v
                   left join products p on p.product_id = v.product_id
                  where v.variation_id = it.variation_id));
  end loop;

  update orders set status = 'packed', packed_at = now(), packed_by = p_operator
   where order_sn = o.order_sn;

  return jsonb_build_object('ok', true, 'order_sn', o.order_sn, 'tracking_no', o.tracking_no,
    'buyer_name', o.buyer_name, 'shop_id', o.shop_id, 'baris', baris);
end $$;

-- ============================================================================
-- 12. PERBAIKAN KEAMANAN #3 — set_role_pin dengan pemeriksaan hasil
--     Kalau cara penyimpanan sandi Supabase berubah, fungsi ini akan
--     MENOLAK dan mengembalikan sandi lama, bukan mengunci kamu di luar.
-- ============================================================================

create or replace function set_role_pin(p_role text, p_pin text)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare uid uuid; lama text; baru text; n integer;
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'bukan_kepala'); end if;
  if p_role not in ('admin','gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'peran_tidak_dikenal'); end if;
  if p_pin is null or length(p_pin) < 4 then
    return jsonb_build_object('ok', false, 'code', 'pin_terlalu_pendek'); end if;
  if p_pin ~ '^(\d)\1+$' or p_pin in ('1234','12345','123456','0000','1111') then
    return jsonb_build_object('ok', false, 'code', 'pin_terlalu_mudah'); end if;

  select user_id into uid from profiles where role = p_role limit 1;
  if uid is null then return jsonb_build_object('ok', false, 'code', 'akun_belum_dibuat'); end if;

  select encrypted_password into lama from auth.users where id = uid;
  update auth.users set encrypted_password = extensions.crypt(p_pin, extensions.gen_salt('bf')),
                        updated_at = now()
   where id = uid;
  get diagnostics n = row_count;
  select encrypted_password into baru from auth.users where id = uid;

  -- pastikan PIN baru benar-benar bisa dipakai masuk
  if n <> 1 or baru is null or extensions.crypt(p_pin, baru) <> baru then
    update auth.users set encrypted_password = lama where id = uid;   -- kembalikan
    return jsonb_build_object('ok', false, 'code', 'gagal_diverifikasi',
      'pesan', 'PIN lama dikembalikan. Ganti lewat dashboard Supabase.');
  end if;

  perform notif('pin_diganti', 'perhatian', 'PIN peran ' || p_role || ' diganti', p_role, null,
                jsonb_build_object('peran', p_role), 'kepala');
  return jsonb_build_object('ok', true, 'role', p_role);
end $$;

-- ============================================================================
-- 13. TAMPILAN BANTU
-- ============================================================================

create or replace view v_pesanan_bermasalah as
select o.order_sn, o.shop_id, o.tracking_no, o.platform, o.status, o.dipaksa, o.alasan_paksa,
       o.packed_at, o.packed_by,
       count(*) filter (where oi.variation_id is null) as baris_belum_cocok,
       count(*) filter (where oi.ditambah_gudang)      as baris_tambahan_gudang,
       count(*) filter (where oi.qty_fix <> 0)         as baris_dikoreksi
from orders o join order_items oi on oi.order_sn = o.order_sn
group by o.order_sn
having count(*) filter (where oi.variation_id is null) > 0
    or count(*) filter (where oi.ditambah_gudang) > 0
    or bool_or(o.dipaksa);
alter view v_pesanan_bermasalah set (security_invoker = on);

-- ============================================================================
-- 14. IZIN
-- ============================================================================

alter table notifikasi   enable row level security;
alter table retur        enable row level security;
alter table retur_items  enable row level security;
alter table opname_sesi  enable row level security;
alter table opname_baris enable row level security;
alter table lcl          enable row level security;
alter table lcl_items    enable row level security;
alter table perangkat    enable row level security;
alter table pengaturan   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['notifikasi','retur','retur_items','opname_sesi','opname_baris',
                           'lcl','lcl_items','perangkat','pengaturan'] loop
    execute format('drop policy if exists baca_semua on %I', t);
    execute format('create policy baca_semua on %I for select to authenticated using (true)', t);
  end loop;
end $$;

-- notifikasi hanya boleh ditutup lewat fungsi; tabelnya sendiri baca saja
revoke insert, update, delete on notifikasi from authenticated;

drop policy if exists tulis_retur on retur;
create policy tulis_retur on retur for all to authenticated
  using (my_role() in ('admin','kepala')) with check (my_role() in ('admin','kepala'));
drop policy if exists tulis_retur_items on retur_items;
create policy tulis_retur_items on retur_items for all to authenticated
  using (my_role() in ('admin','kepala')) with check (my_role() in ('admin','kepala'));

drop policy if exists tulis_opname on opname_sesi;
create policy tulis_opname on opname_sesi for all to authenticated
  using (my_role() in ('gudang','kepala')) with check (my_role() in ('gudang','kepala'));
drop policy if exists tulis_opname_baris on opname_baris;
create policy tulis_opname_baris on opname_baris for all to authenticated
  using (my_role() in ('gudang','kepala')) with check (my_role() in ('gudang','kepala'));

drop policy if exists tulis_lcl on lcl;
create policy tulis_lcl on lcl for all to authenticated
  using (is_kepala()) with check (is_kepala());
drop policy if exists tulis_lcl_items on lcl_items;
create policy tulis_lcl_items on lcl_items for all to authenticated
  using (is_kepala()) with check (is_kepala());

drop policy if exists tulis_perangkat on perangkat;
create policy tulis_perangkat on perangkat for all to authenticated
  using (is_kepala()) with check (is_kepala());
drop policy if exists tulis_pengaturan on pengaturan;
create policy tulis_pengaturan on pengaturan for all to authenticated
  using (is_kepala()) with check (is_kepala());

grant select on v_lcl_progres, v_pesanan_bermasalah to authenticated;
grant execute on function notif(text,text,text,text,text,jsonb,text)          to authenticated;
grant execute on function tutup_notif(bigint,text)                            to authenticated;
grant execute on function catat_perangkat(text,text)                          to authenticated;
grant execute on function perangkat_boleh(text)                               to authenticated;
grant execute on function kirim_paksa(text,text,text,text,text)               to authenticated;
grant execute on function gudang_tambah_barang(text,text,integer,text,text,text,text) to authenticated;
grant execute on function retur_ajukan(text,text,text,text,jsonb,text)         to authenticated;
grant execute on function retur_setujui(uuid,text)                            to authenticated;
grant execute on function retur_tolak(uuid,text,text)                         to authenticated;
grant execute on function retur_terima(uuid,text,text,text)                   to authenticated;
grant execute on function opname_simpan(uuid,text,integer,text)               to authenticated;
grant execute on function opname_ajukan(uuid,text)                            to authenticated;
grant execute on function opname_setujui(uuid,text)                           to authenticated;
grant execute on function scan_out(text,text,text,text)                       to authenticated;
grant execute on function stock_in(text,integer,text,text,text,text,text,uuid,text) to authenticated;

-- versi lama fungsi (jumlah argumen berbeda) dibuang supaya tidak ada dua
drop function if exists scan_out(text,text,text);
drop function if exists stock_in(text,integer,text,text,text,text,text);

-- pembersihan riwayat: ikut sertakan tabel baru
create or replace function purge_riwayat_lama() returns jsonb
language plpgsql security definer set search_path = public as $$
declare a integer; b integer; c integer;
begin
  delete from stock_movements where created_at < now() - interval '1 year';
  get diagnostics a = row_count;
  delete from order_items where order_sn in
    (select order_sn from orders where imported_at < now() - interval '1 year');
  get diagnostics b = row_count;
  delete from orders where imported_at < now() - interval '1 year';
  get diagnostics c = row_count;
  delete from upload_batches where created_at < now() - interval '1 year';
  delete from notifikasi   where dibuat_pada < now() - interval '1 year';
  delete from retur        where dibuat_pada < now() - interval '1 year';
  delete from opname_sesi  where dibuat_pada < now() - interval '1 year';
  return jsonb_build_object('gerakan', a, 'baris_pesanan', b, 'pesanan', c);
end $$;
