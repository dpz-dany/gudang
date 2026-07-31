-- ============================================================================
-- PATCH v6 — SKU Induk, foto tunggal, pengajuan Gudang, dan retensi riwayat
-- Jalankan SETELAH 05_edit_sku.sql. Aman dijalankan berulang kali.
-- ============================================================================

-- Satu baris tampilan untuk satu SKU Induk per toko. Stok tetap tersimpan dan
-- diaudit pada variasi; view ini hanya mengelompokkan layar operasional.
create or replace view v_stock_induk as
select v.shop_id,
       coalesce(nullif(trim(v.parent_sku), ''), v.sku) as sku_induk,
       min(p.product_name) as product_name,
       coalesce(
         min(nullif(p.image_url, '')) filter (where p.image_url is not null),
         min(nullif(v.image_url, '')) filter (where v.image_url is not null)
       ) as image_url,
       count(*)::integer as jumlah_tipe,
       sum(v.stock_on_hand)::integer as stock_on_hand,
       bool_or(v.stock_on_hand <= v.reorder_point) as perlu_restock,
       bool_or(v.stock_on_hand = 0) as ada_stok_kosong,
       bool_or(v.stock_on_hand < 0) as ada_stok_minus
  from variations v
  join products p on p.product_id = v.product_id
 where v.active
 group by v.shop_id, coalesce(nullif(trim(v.parent_sku), ''), v.sku);

alter view v_stock_induk set (security_invoker = on);
grant select on v_stock_induk to authenticated;

-- Foto adalah milik produk/SKU Induk. Migrasi ini juga membersihkan sisa
-- konfigurasi lama per-variasi. Berkas JPG sudah bernama SKU Induk di repo.
update products
   set image_url = parent_sku || '.jpg'
 where nullif(trim(parent_sku), '') is not null;

update variations set image_url = null where image_url is not null;

-- Pastikan perubahan master oleh Kepala juga menulis foto pada level produk.
create or replace function ubah_master_sku(
  p_variation_id text,
  p_sku text,
  p_parent_sku text default null,
  p_product_name text default null,
  p_variation_name text default null,
  p_image_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lama variations%rowtype;
  sku_baru text := trim(coalesce(p_sku,''));
  nama_baru text := trim(coalesce(p_product_name,''));
  variasi_baru text := nullif(trim(coalesce(p_variation_name,'')), '');
  induk_baru text := nullif(trim(coalesce(p_parent_sku,'')), '');
  foto_baru text := nullif(trim(coalesce(p_image_url,'')), '');
begin
  if not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if p_variation_id is null or sku_baru = '' then
    return jsonb_build_object('ok', false, 'code', 'sku_kosong');
  end if;

  select * into lama from variations where variation_id = p_variation_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;
  if nama_baru = '' then return jsonb_build_object('ok', false, 'code', 'nama_produk_kosong'); end if;

  if exists (
    select 1 from variations v
     where v.shop_id = lama.shop_id and v.variation_id <> lama.variation_id
       and norm(v.sku) = norm(sku_baru)
       and norm(coalesce(v.variation_name,'')) = norm(coalesce(variasi_baru,''))
  ) then
    return jsonb_build_object('ok', false, 'code', 'sku_variasi_sudah_ada');
  end if;

  update products set product_name = nama_baru,
                      image_url = foto_baru
   where product_id = lama.product_id;

  update products set parent_sku = induk_baru
   where product_id = lama.product_id
     and parent_sku is not distinct from lama.parent_sku;

  update variations set sku = sku_baru, parent_sku = induk_baru,
         variation_name = variasi_baru, image_url = null, updated_at = now()
   where variation_id = lama.variation_id;

  return jsonb_build_object('ok', true, 'sku_lama', lama.sku, 'sku', sku_baru);
end $$;

grant execute on function ubah_master_sku(text,text,text,text,text,text) to authenticated;

-- Gudang tidak dapat menulis master langsung. Usulan tersimpan dahulu di
-- Supabase dan Kepala Admin yang menerapkan atau menolaknya.
create table if not exists pengajuan_master_sku (
  pengajuan_id  uuid primary key default gen_random_uuid(),
  variation_id  text not null references variations(variation_id) on delete cascade,
  shop_id       text references shops(shop_id) on delete set null,
  sebelum       jsonb not null,
  sesudah       jsonb not null,
  status        text not null default 'menunggu'
                  check (status in ('menunggu','disetujui','ditolak')),
  diajukan_oleh text,
  diajukan_pada timestamptz not null default now(),
  diputus_oleh  text,
  diputus_pada  timestamptz,
  catatan_keputusan text
);

create index if not exists pengajuan_master_status_idx
  on pengajuan_master_sku (status, diajukan_pada desc);
create index if not exists pengajuan_master_variation_idx
  on pengajuan_master_sku (variation_id, status);

alter table pengajuan_master_sku enable row level security;
drop policy if exists baca_pengajuan_master on pengajuan_master_sku;
create policy baca_pengajuan_master on pengajuan_master_sku
  for select to authenticated using (true);
revoke insert, update, delete on pengajuan_master_sku from authenticated;
grant select on pengajuan_master_sku to authenticated;

create or replace function ajukan_ubah_master_sku(
  p_variation_id text,
  p_sku text,
  p_product_name text,
  p_variation_name text default null,
  p_operator text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  lama variations%rowtype;
  nama_lama text;
  sku_baru text := trim(coalesce(p_sku,''));
  nama_baru text := trim(coalesce(p_product_name,''));
  variasi_baru text := nullif(trim(coalesce(p_variation_name,'')), '');
  id_baru uuid;
begin
  if my_role() <> 'gudang' then
    return jsonb_build_object('ok', false, 'code', 'hanya_gudang');
  end if;
  if p_variation_id is null or sku_baru = '' then
    return jsonb_build_object('ok', false, 'code', 'sku_kosong');
  end if;
  if nama_baru = '' then
    return jsonb_build_object('ok', false, 'code', 'nama_produk_kosong');
  end if;

  select * into lama from variations where variation_id = p_variation_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;
  select product_name into nama_lama from products where product_id = lama.product_id;

  if exists (
    select 1 from pengajuan_master_sku
     where variation_id = p_variation_id and status = 'menunggu'
  ) then
    return jsonb_build_object('ok', false, 'code', 'sudah_ada_pengajuan');
  end if;

  if exists (
    select 1 from variations v
     where v.shop_id = lama.shop_id and v.variation_id <> lama.variation_id
       and norm(v.sku) = norm(sku_baru)
       and norm(coalesce(v.variation_name,'')) = norm(coalesce(variasi_baru,''))
  ) then
    return jsonb_build_object('ok', false, 'code', 'sku_variasi_sudah_ada');
  end if;

  insert into pengajuan_master_sku (variation_id, shop_id, sebelum, sesudah, diajukan_oleh)
  values (
    lama.variation_id, lama.shop_id,
    jsonb_build_object('sku', lama.sku, 'product_name', nama_lama,
                       'variation_name', lama.variation_name,
                       'parent_sku', lama.parent_sku),
    jsonb_build_object('sku', sku_baru, 'product_name', nama_baru,
                       'variation_name', variasi_baru,
                       'parent_sku', lama.parent_sku),
    p_operator
  ) returning pengajuan_id into id_baru;

  perform notif('usulan_master_sku', 'perhatian',
    'Gudang mengajukan perubahan SKU ' || lama.sku,
    id_baru::text, lama.shop_id,
    jsonb_build_object('pengajuan_id', id_baru, 'variation_id', lama.variation_id,
                       'sebelum', jsonb_build_object('sku', lama.sku, 'product_name', nama_lama,
                                                       'variation_name', lama.variation_name),
                       'sesudah', jsonb_build_object('sku', sku_baru, 'product_name', nama_baru,
                                                       'variation_name', variasi_baru)),
    p_operator);

  return jsonb_build_object('ok', true, 'pengajuan_id', id_baru);
end $$;

create or replace function setujui_pengajuan_master_sku(
  p_pengajuan_id uuid,
  p_operator text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p pengajuan_master_sku%rowtype;
  lama variations%rowtype;
  nama_baru text;
  sku_baru text;
  variasi_baru text;
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  select * into p from pengajuan_master_sku where pengajuan_id = p_pengajuan_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'pengajuan_tidak_ada'); end if;
  if p.status <> 'menunggu' then return jsonb_build_object('ok', false, 'code', 'sudah_' || p.status); end if;

  select * into lama from variations where variation_id = p.variation_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;
  sku_baru := trim(coalesce(p.sesudah->>'sku', ''));
  nama_baru := trim(coalesce(p.sesudah->>'product_name', ''));
  variasi_baru := nullif(trim(coalesce(p.sesudah->>'variation_name', '')), '');

  if sku_baru = '' or nama_baru = '' then
    return jsonb_build_object('ok', false, 'code', 'data_pengajuan_tidak_lengkap');
  end if;
  if exists (
    select 1 from variations v
     where v.shop_id = lama.shop_id and v.variation_id <> lama.variation_id
       and norm(v.sku) = norm(sku_baru)
       and norm(coalesce(v.variation_name,'')) = norm(coalesce(variasi_baru,''))
  ) then
    return jsonb_build_object('ok', false, 'code', 'sku_variasi_sudah_ada');
  end if;

  update products set product_name = nama_baru where product_id = lama.product_id;
  update variations set sku = sku_baru, variation_name = variasi_baru, updated_at = now()
   where variation_id = lama.variation_id;
  update pengajuan_master_sku set status = 'disetujui', diputus_oleh = p_operator,
         diputus_pada = now() where pengajuan_id = p.pengajuan_id;
  update notifikasi set status = 'selesai', ditutup_oleh = p_operator, ditutup_pada = now(),
         catatan = 'Disetujui' where jenis = 'usulan_master_sku'
           and ref = p.pengajuan_id::text and status <> 'selesai';

  perform notif('usulan_master_sku_disetujui', 'info',
    'Usulan perubahan SKU ' || lama.sku || ' disetujui',
    p.pengajuan_id::text, lama.shop_id,
    jsonb_build_object('pengajuan_id', p.pengajuan_id, 'sku_lama', lama.sku, 'sku_baru', sku_baru),
    p_operator);
  return jsonb_build_object('ok', true, 'sku', sku_baru);
end $$;

create or replace function tolak_pengajuan_master_sku(
  p_pengajuan_id uuid,
  p_catatan text default null,
  p_operator text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare p pengajuan_master_sku%rowtype;
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  select * into p from pengajuan_master_sku where pengajuan_id = p_pengajuan_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'pengajuan_tidak_ada'); end if;
  if p.status <> 'menunggu' then return jsonb_build_object('ok', false, 'code', 'sudah_' || p.status); end if;

  update pengajuan_master_sku set status = 'ditolak', diputus_oleh = p_operator,
         diputus_pada = now(), catatan_keputusan = nullif(trim(coalesce(p_catatan,'')), '')
   where pengajuan_id = p.pengajuan_id;
  update notifikasi set status = 'selesai', ditutup_oleh = p_operator, ditutup_pada = now(),
         catatan = coalesce(nullif(trim(coalesce(p_catatan,'')), ''), 'Ditolak')
   where jenis = 'usulan_master_sku' and ref = p.pengajuan_id::text and status <> 'selesai';
  return jsonb_build_object('ok', true);
end $$;

grant execute on function ajukan_ubah_master_sku(text,text,text,text,text) to authenticated;
grant execute on function setujui_pengajuan_master_sku(uuid,text) to authenticated;
grant execute on function tolak_pengajuan_master_sku(uuid,text,text) to authenticated;

-- Redirect otomatis setelah browser sudah punya sesi dipisahkan ke pengaturan
-- Supabase. Default OFF untuk tahap pengujian.
insert into pengaturan (kunci, nilai) values ('auto_arah_login', 'off')
on conflict (kunci) do nothing;

create or replace function auto_arah_login_aktif()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select nilai = 'on' from pengaturan where kunci = 'auto_arah_login'), false)
$$;
grant execute on function auto_arah_login_aktif() to authenticated;

-- Semua catatan operasional dihapus ketika umurnya lebih dari satu tahun.
-- Master SKU, toko, akun, pengaturan, dan buku terjemahan sengaja dipertahankan.
create or replace function purge_riwayat_lama() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  batas timestamptz := now() - interval '1 year';
  gerakan integer; pesanan integer; batch integer; notifs integer;
  retur_lama integer; opname_lama integer; lcl_lama integer;
  pengajuan_lama integer; perangkat_lama integer;
begin
  delete from stock_movements where created_at < batas;
  get diagnostics gerakan = row_count;

  delete from orders where imported_at < batas;
  get diagnostics pesanan = row_count;
  delete from upload_batches where created_at < batas;
  get diagnostics batch = row_count;

  delete from notifikasi where dibuat_pada < batas;
  get diagnostics notifs = row_count;
  delete from retur where dibuat_pada < batas;
  get diagnostics retur_lama = row_count;
  delete from opname_sesi where dibuat_pada < batas;
  get diagnostics opname_lama = row_count;
  delete from pengajuan_master_sku where diajukan_pada < batas;
  get diagnostics pengajuan_lama = row_count;
  delete from perangkat where coalesce(terakhir, dibuat_pada) < batas;
  get diagnostics perangkat_lama = row_count;

  -- Jangan hapus kiriman lama jika masih dirujuk gerakan stok yang belum kadaluarsa.
  delete from lcl l
   where l.dibuat_pada < batas
     and not exists (select 1 from stock_movements m where m.lcl_id = l.lcl_id);
  get diagnostics lcl_lama = row_count;

  return jsonb_build_object(
    'gerakan', gerakan, 'pesanan', pesanan, 'batch', batch,
    'notifikasi', notifs, 'retur', retur_lama, 'opname', opname_lama,
    'lcl', lcl_lama, 'pengajuan_master', pengajuan_lama, 'perangkat', perangkat_lama
  );
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('purge-riwayat') where exists
      (select 1 from cron.job where jobname = 'purge-riwayat');
    perform cron.schedule('purge-riwayat', '0 3 1 * *', 'select purge_riwayat_lama()');
  end if;
exception when others then null;
end $$;
