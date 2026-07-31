-- ============================================================================
-- PATCH v7 - persetujuan stok masuk Gudang + penguatan keamanan
-- Jalankan SETELAH 06_sku_induk_dan_persetujuan.sql.
-- Aman dijalankan berulang kali.
-- ============================================================================

-- Gudang hanya membuat pengajuan. Stok aktual baru berubah secara atomik ketika
-- Kepala Admin menyetujui pengajuan tersebut.
create table if not exists pengajuan_stok_masuk (
  pengajuan_id       uuid primary key default gen_random_uuid(),
  variation_id       text not null references variations(variation_id) on delete cascade,
  shop_id            text references shops(shop_id) on delete set null,
  sku_saat_diajukan  text not null,
  qty                 integer not null check (qty > 0),
  stok_saat_diajukan integer not null,
  stok_setelah       integer,
  catatan             text,
  client_id           text,
  device_id           text,
  status              text not null default 'menunggu'
                        check (status in ('menunggu','disetujui','ditolak')),
  diajukan_oleh       text,
  diajukan_pada       timestamptz not null default now(),
  diputus_oleh        text,
  diputus_pada        timestamptz,
  catatan_keputusan   text
);

create unique index if not exists pengajuan_stok_client_idx
  on pengajuan_stok_masuk (client_id) where client_id is not null;
create index if not exists pengajuan_stok_status_idx
  on pengajuan_stok_masuk (status, diajukan_pada desc);
create index if not exists pengajuan_stok_variasi_idx
  on pengajuan_stok_masuk (variation_id, status);

alter table pengajuan_stok_masuk enable row level security;
drop policy if exists baca_pengajuan_stok on pengajuan_stok_masuk;
create policy baca_pengajuan_stok on pengajuan_stok_masuk
  for select to authenticated using (true);
revoke insert, update, delete on pengajuan_stok_masuk from public, anon, authenticated;
grant select on pengajuan_stok_masuk to authenticated;

create or replace function ajukan_stok_masuk(
  p_variation_id text,
  p_qty integer,
  p_note text default null,
  p_operator text default null,
  p_client_id text default null,
  p_device text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v variations%rowtype;
  id_baru uuid;
  lama pengajuan_stok_masuk%rowtype;
begin
  if my_role() <> 'gudang' then
    return jsonb_build_object('ok', false, 'code', 'hanya_gudang');
  end if;
  if p_variation_id is null or coalesce(p_qty, 0) <= 0 then
    return jsonb_build_object('ok', false, 'code', 'jumlah_tidak_valid');
  end if;
  if p_client_id is not null then
    select * into lama from pengajuan_stok_masuk where client_id = p_client_id;
    if found then
      return jsonb_build_object(
        'ok', true, 'duplikat_sinkron', true, 'pengajuan_id', lama.pengajuan_id,
        'status', lama.status, 'qty', lama.qty, 'sku', lama.sku_saat_diajukan
      );
    end if;
  end if;

  perform catat_perangkat(p_device, 'gudang');
  select * into v from variations where variation_id = p_variation_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;
  if not v.active then return jsonb_build_object('ok', false, 'code', 'sku_nonaktif'); end if;

  begin
    insert into pengajuan_stok_masuk (
      variation_id, shop_id, sku_saat_diajukan, qty, stok_saat_diajukan,
      catatan, client_id, device_id, diajukan_oleh
    ) values (
      v.variation_id, v.shop_id, v.sku, p_qty, v.stock_on_hand,
      nullif(trim(coalesce(p_note, '')), ''), p_client_id, p_device, p_operator
    ) returning pengajuan_id into id_baru;
  exception when unique_violation then
    select * into lama from pengajuan_stok_masuk where client_id = p_client_id;
    return jsonb_build_object(
      'ok', true, 'duplikat_sinkron', true, 'pengajuan_id', lama.pengajuan_id,
      'status', lama.status, 'qty', lama.qty, 'sku', lama.sku_saat_diajukan
    );
  end;

  perform notif(
    'stok_masuk_diajukan', 'perhatian',
    'Gudang mengajukan stok masuk ' || v.sku || ' +' || p_qty,
    id_baru::text, v.shop_id,
    jsonb_build_object(
      'pengajuan_id', id_baru, 'variation_id', v.variation_id,
      'sku', v.sku, 'qty', p_qty, 'stok_saat_diajukan', v.stock_on_hand,
      'catatan', nullif(trim(coalesce(p_note, '')), ''),
      'perangkat', p_device
    ),
    p_operator
  );

  return jsonb_build_object(
    'ok', true, 'pengajuan_id', id_baru, 'status', 'menunggu',
    'variation_id', v.variation_id, 'sku', v.sku, 'qty', p_qty,
    'stok_saat_diajukan', v.stock_on_hand
  );
end $$;

create or replace function setujui_pengajuan_stok_masuk(
  p_pengajuan_id uuid,
  p_operator text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p pengajuan_stok_masuk%rowtype;
  v variations%rowtype;
  bal integer;
begin
  if not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;

  select * into p from pengajuan_stok_masuk
   where pengajuan_id = p_pengajuan_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'pengajuan_tidak_ada'); end if;
  if p.status <> 'menunggu' then
    return jsonb_build_object('ok', false, 'code', 'sudah_' || p.status);
  end if;

  select * into v from variations where variation_id = p.variation_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;
  if not v.active then return jsonb_build_object('ok', false, 'code', 'sku_nonaktif'); end if;

  update variations
     set stock_on_hand = stock_on_hand + p.qty, updated_at = now()
   where variation_id = p.variation_id
   returning stock_on_hand into bal;

  insert into stock_movements (
    shop_id, variation_id, sku, delta, balance_after, reason, ref, note,
    operator, client_scan_id, device_id
  ) values (
    v.shop_id, v.variation_id, v.sku, p.qty, bal, 'masuk',
    'pengajuan:' || p.pengajuan_id::text,
    concat_ws(' | ', 'Disetujui Kepala Admin', p.catatan),
    p_operator, 'setujui-stok:' || p.pengajuan_id::text, p.device_id
  );

  update pengajuan_stok_masuk
     set status = 'disetujui', stok_setelah = bal,
         diputus_oleh = p_operator, diputus_pada = now()
   where pengajuan_id = p.pengajuan_id;

  update notifikasi
     set status = 'selesai', ditutup_oleh = p_operator, ditutup_pada = now(),
         catatan = 'Disetujui; stok menjadi ' || bal
   where jenis = 'stok_masuk_diajukan' and ref = p.pengajuan_id::text
     and status <> 'selesai';

  return jsonb_build_object(
    'ok', true, 'pengajuan_id', p.pengajuan_id, 'sku', v.sku,
    'qty', p.qty, 'sisa', bal
  );
end $$;

create or replace function tolak_pengajuan_stok_masuk(
  p_pengajuan_id uuid,
  p_catatan text default null,
  p_operator text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare p pengajuan_stok_masuk%rowtype;
begin
  if not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  select * into p from pengajuan_stok_masuk
   where pengajuan_id = p_pengajuan_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'pengajuan_tidak_ada'); end if;
  if p.status <> 'menunggu' then
    return jsonb_build_object('ok', false, 'code', 'sudah_' || p.status);
  end if;

  update pengajuan_stok_masuk
     set status = 'ditolak', diputus_oleh = p_operator, diputus_pada = now(),
         catatan_keputusan = nullif(trim(coalesce(p_catatan, '')), '')
   where pengajuan_id = p.pengajuan_id;

  update notifikasi
     set status = 'selesai', ditutup_oleh = p_operator, ditutup_pada = now(),
         catatan = coalesce(nullif(trim(coalesce(p_catatan, '')), ''), 'Ditolak')
   where jenis = 'stok_masuk_diajukan' and ref = p.pengajuan_id::text
     and status <> 'selesai';

  return jsonb_build_object('ok', true, 'pengajuan_id', p.pengajuan_id);
end $$;

revoke execute on function ajukan_stok_masuk(text,integer,text,text,text,text) from public, anon;
revoke execute on function setujui_pengajuan_stok_masuk(uuid,text) from public, anon;
revoke execute on function tolak_pengajuan_stok_masuk(uuid,text,text) from public, anon;
grant execute on function ajukan_stok_masuk(text,integer,text,text,text,text) to authenticated;
grant execute on function setujui_pengajuan_stok_masuk(uuid,text) to authenticated;
grant execute on function tolak_pengajuan_stok_masuk(uuid,text,text) to authenticated;

-- Tutup jalur lama: peran Gudang tidak boleh lagi mengubah stok langsung.
-- Kepala Admin tetap dapat memakai fungsi ini untuk perubahan yang ia lakukan.
create or replace function stock_in(
  p_variation_id text, p_qty integer, p_reason text default 'masuk',
  p_note text default null, p_ref text default null,
  p_operator text default null, p_client_id text default null,
  p_lcl_id uuid default null, p_device text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare bal integer; prev integer; d integer; sh text; sk text; lref text; r text;
begin
  r := my_role();
  if r not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if r = 'gudang' then
    return jsonb_build_object('ok', false, 'code', 'stok_masuk_perlu_persetujuan');
  end if;
  if p_qty is null or (p_reason <> 'opname' and p_qty <= 0) then
    return jsonb_build_object('ok', false, 'code', 'jumlah_tidak_valid');
  end if;
  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id = p_client_id) then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true);
  end if;

  select shop_id, sku, stock_on_hand into sh, sk, prev
    from variations where variation_id = p_variation_id for update;
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
               then concat_ws(' | ', p_note, 'hitung fisik ' || p_qty || ' (sistem ' || prev || ')')
               else p_note end,
          p_operator, p_client_id, p_lcl_id, p_device);

  return jsonb_build_object('ok', true, 'variation_id', p_variation_id, 'sku', sk,
                            'sisa', bal, 'lcl', lref);
end $$;

revoke execute on function stock_in(text,integer,text,text,text,text,text,uuid,text) from public, anon;
grant execute on function stock_in(text,integer,text,text,text,text,text,uuid,text) to authenticated;

-- SKU Induk adalah milik produk, jadi saat Kepala mengubahnya seluruh variasi
-- di bawah produk tersebut harus ikut pindah kelompok.
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

  update products
     set product_name = nama_baru, parent_sku = induk_baru, image_url = foto_baru
   where product_id = lama.product_id;

  update variations
     set parent_sku = induk_baru, image_url = null, updated_at = now()
   where product_id = lama.product_id;

  update variations
     set sku = sku_baru, variation_name = variasi_baru, updated_at = now()
   where variation_id = lama.variation_id;

  return jsonb_build_object(
    'ok', true, 'sku_lama', lama.sku, 'sku', sku_baru,
    'parent_sku', induk_baru
  );
end $$;

revoke execute on function ubah_master_sku(text,text,text,text,text,text) from public, anon;
grant execute on function ubah_master_sku(text,text,text,text,text,text) to authenticated;

-- View harga harus berjalan dengan hak pemanggil agar RLS tidak dilewati.
alter view v_stock set (security_invoker = on);
alter view v_stock_induk set (security_invoker = on);
alter view v_stock_nilai set (security_invoker = on);

-- Fungsi internal tidak boleh dipanggil langsung dari API.
revoke execute on function notif(text,text,text,text,text,jsonb,text) from public, anon, authenticated;
revoke execute on function catat_perangkat(text,text) from public, anon, authenticated;
revoke execute on function perangkat_boleh(text) from public, anon, authenticated;
revoke execute on function auto_arah_login_aktif() from public, anon;
grant execute on function auto_arah_login_aktif() to authenticated;

-- Semua catatan operasional yang berumur lebih dari satu tahun dibuang.
-- Master SKU, toko, akun, pengaturan, dan alias produk tetap dipertahankan.
create or replace function purge_riwayat_lama() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  batas timestamptz := now() - interval '1 year';
  gerakan integer; pesanan integer; batch integer; notifs integer;
  retur_lama integer; opname_lama integer; lcl_lama integer;
  pengajuan_master_lama integer; pengajuan_stok_lama integer; perangkat_lama integer;
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
  get diagnostics pengajuan_master_lama = row_count;
  delete from pengajuan_stok_masuk where diajukan_pada < batas;
  get diagnostics pengajuan_stok_lama = row_count;
  delete from perangkat where coalesce(terakhir, dibuat_pada) < batas;
  get diagnostics perangkat_lama = row_count;

  delete from lcl l
   where l.dibuat_pada < batas
     and not exists (select 1 from stock_movements m where m.lcl_id = l.lcl_id);
  get diagnostics lcl_lama = row_count;

  return jsonb_build_object(
    'gerakan', gerakan, 'pesanan', pesanan, 'batch', batch,
    'notifikasi', notifs, 'retur', retur_lama, 'opname', opname_lama,
    'lcl', lcl_lama, 'pengajuan_master', pengajuan_master_lama,
    'pengajuan_stok', pengajuan_stok_lama, 'perangkat', perangkat_lama
  );
end $$;

revoke execute on function purge_riwayat_lama() from public, anon, authenticated;

do $$
declare j bigint;
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    for j in select jobid from cron.job where jobname = 'purge-riwayat' loop
      perform cron.unschedule(j);
    end loop;
    perform cron.schedule(
      'purge-riwayat', '0 3 1 * *', 'select public.purge_riwayat_lama()'
    );
  end if;
end $$;
