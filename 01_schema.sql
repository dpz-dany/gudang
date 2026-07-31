-- ============================================================================
--  SISTEM GUDANG  v2
--  Jalankan SEKALI di Supabase → SQL Editor → New query → Run
--  Aman dijalankan ulang (idempotent).
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ============================================================================
--  1. PERAN & PIN
-- ============================================================================

create table if not exists profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  role         text not null check (role in ('admin','gudang','kepala')),
  display_name text,
  created_at   timestamptz default now()
);

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where user_id = auth.uid()
$$;

create or replace function is_kepala() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role() = 'kepala', false)
$$;

-- Kepala Admin dapat mengubah PIN peran lain tanpa membuka Supabase.
-- GoTrue memakai bcrypt, jadi kita tulis langsung ke auth.users.
create or replace function set_role_pin(p_role text, p_pin text)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare n integer;
begin
  if not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'bukan_kepala');
  end if;
  if p_role not in ('admin','gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'peran_tidak_dikenal');
  end if;
  if p_pin is null or length(p_pin) < 4 then
    return jsonb_build_object('ok', false, 'code', 'pin_terlalu_pendek');
  end if;

  update auth.users u
     set encrypted_password = extensions.crypt(p_pin, extensions.gen_salt('bf')),
         updated_at = now()
   where u.id in (select user_id from profiles where role = p_role);
  get diagnostics n = row_count;

  if n = 0 then return jsonb_build_object('ok', false, 'code', 'akun_belum_dibuat'); end if;
  return jsonb_build_object('ok', true, 'role', p_role);
end $$;

-- ============================================================================
--  2. TOKO
-- ============================================================================

create table if not exists shops (
  shop_id      text primary key,
  name         text not null,
  sender_names text[] not null default '{}',   -- nama "Pengirim" di label
  active       boolean not null default true,
  created_at   timestamptz default now()
);

-- normalisasi teks untuk pencocokan nama
create or replace function norm(t text) returns text
language sql immutable as $$
  select regexp_replace(lower(coalesce(t,'')), '[^a-z0-9]+', '', 'g')
$$;

-- tebak toko dari nama Pengirim yang tercetak di label
create or replace function shop_from_sender(p_sender text)
returns text language sql stable as $$
  select s.shop_id from shops s
   where s.active
     and (norm(s.name) = norm(p_sender)
          or exists (select 1 from unnest(s.sender_names) a where norm(a) = norm(p_sender)))
   limit 1
$$;

-- ============================================================================
--  3. MASTER PRODUK
-- ============================================================================

create table if not exists products (
  product_id   text primary key,
  shop_id      text references shops(shop_id) on delete cascade,
  product_name text not null,
  parent_sku   text,
  image_url    text,
  created_at   timestamptz default now()
);
create index if not exists products_shop_idx on products (shop_id);
create index if not exists products_name_idx on products (norm(product_name));

create table if not exists variations (
  variation_id   text primary key,
  product_id     text references products(product_id) on delete cascade,
  shop_id        text references shops(shop_id) on delete cascade,
  sku            text not null,
  parent_sku     text,
  variation_name text,
  price          numeric(14,2),                -- sengaja NULL = belum diisi
  stock_on_hand  integer not null default 0,
  reorder_point  integer not null default 0,
  image_url      text,
  active         boolean not null default true,
  updated_at     timestamptz default now()
);
create index if not exists variations_sku_idx    on variations (shop_id, norm(sku));
create index if not exists variations_parent_idx on variations (shop_id, norm(parent_sku));
create index if not exists variations_prod_idx   on variations (product_id);

-- ============================================================================
--  4. BATCH UNGGAHAN (Admin Harian)
-- ============================================================================

create table if not exists upload_batches (
  batch_id     uuid primary key default gen_random_uuid(),
  shop_id      text references shops(shop_id),
  file_names   text[],
  n_orders     integer default 0,
  n_items      integer default 0,
  n_fixed      integer default 0,             -- baris yang dikoreksi admin
  fix_ratio    numeric(5,4) default 0,
  status       text not null default 'draft' check (status in ('draft','confirmed')),
  created_by   text,
  created_at   timestamptz default now(),
  confirmed_at timestamptz
);

-- ============================================================================
--  5. PESANAN
-- ============================================================================

create table if not exists orders (
  order_sn     text primary key,
  shop_id      text references shops(shop_id),
  batch_id     uuid references upload_batches(batch_id) on delete set null,
  tracking_no  text,
  buyer_name   text,
  ship_by      date,
  service      text,
  page_count   integer default 1,
  status       text not null default 'pending'
                 check (status in ('pending','packed','cancelled')),
  source       text,
  imported_at  timestamptz default now(),
  packed_at    timestamptz,
  packed_by    text
);
create index if not exists orders_tracking_idx on orders (norm(tracking_no));
create index if not exists orders_status_idx   on orders (status, shop_id);
create index if not exists orders_batch_idx    on orders (batch_id);

create table if not exists order_items (
  id             bigserial primary key,
  order_sn       text references orders(order_sn) on delete cascade,
  line_no        integer,
  sku_label      text,              -- apa adanya dari label (bisa kosong!)
  variation_name text,
  product_name   text,
  qty_label      integer not null default 0,   -- hasil baca PDF
  qty_fix        integer not null default 0,   -- "+FIX" dari Admin Harian
  qty_final      integer generated always as (qty_label + qty_fix) stored,
  variation_id   text references variations(variation_id) on delete set null,
  resolve_method text,              -- sku | sku+variasi | induk+variasi | nama+variasi | nama | manual
  fixed_by       text,
  fixed_at       timestamptz
);
create index if not exists order_items_order_idx on order_items (order_sn);

-- ============================================================================
--  6. BUKU BESAR STOK
-- ============================================================================

create table if not exists stock_movements (
  id             bigserial primary key,
  shop_id        text,
  variation_id   text references variations(variation_id) on delete set null,
  sku            text,
  delta          integer not null,
  balance_after  integer,
  reason         text not null,   -- keluar | masuk | opname | batal | koreksi
  ref            text,
  note           text,
  operator       text,
  client_scan_id text unique,     -- kunci anti-dobel saat sinkron offline
  created_at     timestamptz default now()
);
create index if not exists mv_ref_idx     on stock_movements (ref);
create index if not exists mv_created_idx on stock_movements (created_at desc);
create index if not exists mv_var_idx     on stock_movements (variation_id);

-- ============================================================================
--  7. TAMPILAN (VIEW)
--  Harga & nilai stok HANYA untuk Kepala Admin — dipaksa di sisi server.
-- ============================================================================

create or replace view v_stock as
select v.variation_id, v.shop_id, s.name as shop_name, v.sku, v.parent_sku,
       v.variation_name, p.product_name,
       coalesce(v.image_url, p.image_url) as image_url,
       v.stock_on_hand, v.reorder_point, v.active,
       (v.stock_on_hand <= v.reorder_point) as perlu_restock,
       v.updated_at
from variations v
left join products p on p.product_id = v.product_id
left join shops   s on s.shop_id     = v.shop_id;

create or replace view v_stock_nilai as
select v.variation_id, v.shop_id, v.sku, p.product_name, v.variation_name,
       v.price, v.stock_on_hand,
       (v.price * v.stock_on_hand) as nilai
from variations v
left join products p on p.product_id = v.product_id
where is_kepala();                        -- kosong untuk peran lain

create or replace view v_sku_ganda as
select shop_id, norm(sku) as sku_key, count(*) as n,
       string_agg(variation_id, ', ') as variation_ids
from variations where active
group by shop_id, norm(sku) having count(*) > 1;

alter view v_stock       set (security_invoker = on);
alter view v_stock_nilai set (security_invoker = on);
alter view v_sku_ganda   set (security_invoker = on);

-- ============================================================================
--  8. PENCOCOKAN SKU
--  Label Shopee sering TIDAK mencetak SKU sama sekali. Urutan usaha:
--    1 SKU persis · 2 SKU+variasi · 3 SKU induk+variasi
--    4 nama produk+variasi · 5 nama produk yang cuma punya 1 variasi
-- ============================================================================

create or replace function resolve_variation(
  p_shop text, p_sku text, p_variation text default null, p_product text default null)
returns table (variation_id text, method text, matches integer)
language plpgsql stable as $$
declare n integer;
begin
  if coalesce(trim(p_sku),'') <> '' then
    select count(*) into n from variations v
     where v.active and v.shop_id = p_shop and norm(v.sku) = norm(p_sku);

    if n = 1 then
      return query select v.variation_id, 'sku', 1 from variations v
       where v.active and v.shop_id = p_shop and norm(v.sku) = norm(p_sku); return;
    end if;

    if n > 1 and p_variation is not null then
      select count(*) into n from variations v
       where v.active and v.shop_id = p_shop and norm(v.sku) = norm(p_sku)
         and norm(v.variation_name) = norm(p_variation);
      if n = 1 then
        return query select v.variation_id, 'sku+variasi', 1 from variations v
         where v.active and v.shop_id = p_shop and norm(v.sku) = norm(p_sku)
           and norm(v.variation_name) = norm(p_variation); return;
      end if;
      return query select null::text, 'sku ganda', n; return;
    end if;

    if n > 1 then return query select null::text, 'sku ganda', n; return; end if;

    if p_variation is not null then
      select count(*) into n from variations v
       where v.active and v.shop_id = p_shop and norm(v.parent_sku) = norm(p_sku)
         and norm(v.variation_name) = norm(p_variation);
      if n = 1 then
        return query select v.variation_id, 'induk+variasi', 1 from variations v
         where v.active and v.shop_id = p_shop and norm(v.parent_sku) = norm(p_sku)
           and norm(v.variation_name) = norm(p_variation); return;
      end if;
    end if;
  end if;

  -- ---- tidak ada SKU di label: cocokkan lewat nama produk ----
  if coalesce(trim(p_product),'') <> '' then
    if p_variation is not null then
      select count(*) into n from variations v join products p on p.product_id = v.product_id
       where v.active and v.shop_id = p_shop
         and norm(p.product_name) = norm(p_product)
         and norm(v.variation_name) = norm(p_variation);
      if n = 1 then
        return query select v.variation_id, 'nama+variasi', 1
          from variations v join products p on p.product_id = v.product_id
         where v.active and v.shop_id = p_shop
           and norm(p.product_name) = norm(p_product)
           and norm(v.variation_name) = norm(p_variation); return;
      end if;
    end if;

    -- produk yang hanya punya satu variasi: nama saja sudah cukup
    select count(*) into n from variations v join products p on p.product_id = v.product_id
     where v.active and v.shop_id = p_shop and norm(p.product_name) = norm(p_product);
    if n = 1 then
      return query select v.variation_id, 'nama', 1
        from variations v join products p on p.product_id = v.product_id
       where v.active and v.shop_id = p_shop and norm(p.product_name) = norm(p_product); return;
    end if;
    if n > 1 then return query select null::text, 'nama ganda', n; return; end if;
  end if;

  return query select null::text, 'tidak ditemukan', 0;
end $$;

-- dipakai layar impor Admin Harian untuk pratinjau sebelum konfirmasi
create or replace function resolve_batch(p_batch uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare it record; v text; m text; c integer; n integer := 0;
begin
  for it in select oi.*, o.shop_id from order_items oi
              join orders o on o.order_sn = oi.order_sn
             where o.batch_id = p_batch loop
    select r.variation_id, r.method, r.matches into v, m, c
      from resolve_variation(it.shop_id, it.sku_label, it.variation_name, it.product_name) r;
    update order_items set variation_id = v, resolve_method = m where id = it.id;
    if v is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ============================================================================
--  9. AKSI STOK
-- ============================================================================

create or replace function scan_out(
  p_scan text, p_operator text default null, p_client_id text default null)
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

  -- Sinkron ulang dari antrean offline: satu pemindaian menulis beberapa baris
  -- buku besar, masing-masing berkunci "<client_id>:<id_baris>". Cek awalannya,
  -- bukan nilai persis, kalau tidak potongan kedua akan lolos.
  if p_client_id is not null and exists (
       select 1 from stock_movements where client_scan_id like p_client_id || ':%') then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true, 'code', 'sudah_tersinkron');
  end if;

  select * into o from orders
   where norm(order_sn) = key or norm(tracking_no) = key limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'pesanan_tidak_ada', 'scan', p_scan);
  end if;
  if o.status = 'packed' then
    return jsonb_build_object('ok', false, 'code', 'sudah_dipindai',
      'order_sn', o.order_sn, 'packed_at', o.packed_at, 'packed_by', o.packed_by);
  end if;
  if o.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'code', 'dibatalkan', 'order_sn', o.order_sn);
  end if;
  if not exists (select 1 from upload_batches b where b.batch_id = o.batch_id and b.status = 'confirmed')
     and o.batch_id is not null then
    return jsonb_build_object('ok', false, 'code', 'batch_belum_dikonfirmasi', 'order_sn', o.order_sn);
  end if;

  -- putaran 1: pastikan SEMUA baris terpetakan sebelum stok disentuh
  for it in select * from order_items where order_sn = o.order_sn loop
    if it.variation_id is null then
      belum := belum || jsonb_build_object('sku', it.sku_label, 'variasi', it.variation_name,
                 'produk', it.product_name, 'qty', it.qty_final, 'sebab', coalesce(it.resolve_method,'?'));
    end if;
  end loop;
  if jsonb_array_length(belum) > 0 then
    return jsonb_build_object('ok', false, 'code', 'sku_belum_cocok',
      'order_sn', o.order_sn, 'belum', belum);
  end if;

  -- putaran 2: potong stok
  for it in select * from order_items where order_sn = o.order_sn loop
    update variations set stock_on_hand = stock_on_hand - it.qty_final, updated_at = now()
     where variation_id = it.variation_id returning stock_on_hand into bal;

    insert into stock_movements (shop_id, variation_id, sku, delta, balance_after,
                                 reason, ref, operator, client_scan_id)
    values (o.shop_id, it.variation_id,
            (select sku from variations where variation_id = it.variation_id),
            -it.qty_final, bal, 'keluar', o.order_sn, p_operator,
            case when p_client_id is null then null else p_client_id || ':' || it.id end);

    baris := baris || jsonb_build_object('sku', (select sku from variations where variation_id = it.variation_id),
      'variation_id', it.variation_id, 'variasi', it.variation_name, 'produk', it.product_name,
      'qty', it.qty_final, 'qty_fix', it.qty_fix, 'sisa', bal, 'minus', (bal < 0),
      'gambar', (select coalesce(v.image_url, p.image_url) from variations v
                   left join products p on p.product_id = v.product_id
                  where v.variation_id = it.variation_id));
  end loop;

  update orders set status = 'packed', packed_at = now(), packed_by = p_operator
   where order_sn = o.order_sn;

  return jsonb_build_object('ok', true, 'order_sn', o.order_sn, 'tracking_no', o.tracking_no,
    'buyer_name', o.buyer_name, 'shop_id', o.shop_id, 'baris', baris);
end $$;


create or replace function undo_scan(p_order_sn text, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare mv record; bal integer; n integer := 0;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if not exists (select 1 from orders where norm(order_sn) = norm(p_order_sn) and status = 'packed') then
    return jsonb_build_object('ok', false, 'code', 'belum_dipindai');
  end if;

  for mv in select * from stock_movements
             where norm(ref) = norm(p_order_sn) and reason = 'keluar' loop
    update variations set stock_on_hand = stock_on_hand - mv.delta, updated_at = now()
     where variation_id = mv.variation_id returning stock_on_hand into bal;
    insert into stock_movements (shop_id, variation_id, sku, delta, balance_after,
                                 reason, ref, note, operator)
    values (mv.shop_id, mv.variation_id, mv.sku, -mv.delta, bal, 'batal',
            p_order_sn, 'pembatalan gerakan #' || mv.id, p_operator);
    n := n + 1;
  end loop;

  update orders set status = 'pending', packed_at = null, packed_by = null
   where norm(order_sn) = norm(p_order_sn);
  return jsonb_build_object('ok', true, 'baris', n);
end $$;


create or replace function stock_in(
  p_variation_id text, p_qty integer, p_reason text default 'masuk',
  p_note text default null, p_ref text default null,
  p_operator text default null, p_client_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare bal integer; prev integer; d integer; sh text; sk text;
begin
  if my_role() not in ('gudang','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  if p_reason = 'opname' and not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'opname_hanya_kepala');
  end if;
  if p_client_id is not null and exists (select 1 from stock_movements where client_scan_id = p_client_id) then
    return jsonb_build_object('ok', true, 'duplikat_sinkron', true);
  end if;

  select shop_id, sku, stock_on_hand into sh, sk, prev
    from variations where variation_id = p_variation_id;
  if sk is null then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;

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
                               reason, ref, note, operator, client_scan_id)
  values (sh, p_variation_id, sk, d, bal, p_reason, p_ref,
          case when p_reason = 'opname'
               then coalesce(p_note || ' · ','') || 'hitung fisik ' || p_qty || ' (sistem ' || prev || ')'
               else p_note end,
          p_operator, p_client_id);

  return jsonb_build_object('ok', true, 'variation_id', p_variation_id, 'sku', sk, 'sisa', bal);
end $$;


-- Admin Harian menekan "Konfirmasi": batch dikunci dan pesanan siap dipindai.
create or replace function confirm_batch(p_batch uuid, p_operator text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n_ord integer; n_it integer; n_fix integer; n_ok integer;
begin
  if my_role() not in ('admin','kepala') then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;
  n_ok := resolve_batch(p_batch);
  select count(distinct o.order_sn), count(oi.id), count(*) filter (where oi.qty_fix <> 0)
    into n_ord, n_it, n_fix
    from orders o join order_items oi on oi.order_sn = o.order_sn
   where o.batch_id = p_batch;

  update upload_batches
     set status='confirmed', confirmed_at=now(), created_by=coalesce(created_by,p_operator),
         n_orders=n_ord, n_items=n_it, n_fixed=n_fix,
         fix_ratio = case when n_it > 0 then n_fix::numeric / n_it else 0 end
   where batch_id = p_batch;

  return jsonb_build_object('ok', true, 'pesanan', n_ord, 'baris', n_it,
    'dikoreksi', n_fix, 'cocok', n_ok,
    'rasio_koreksi', case when n_it > 0 then round(n_fix::numeric / n_it, 4) else 0 end);
end $$;

-- ============================================================================
-- 10. KEAMANAN (RLS) — dipaksa di server, bukan di browser
-- ============================================================================

alter table profiles        enable row level security;
alter table shops           enable row level security;
alter table products        enable row level security;
alter table variations      enable row level security;
alter table upload_batches  enable row level security;
alter table orders          enable row level security;
alter table order_items     enable row level security;
alter table stock_movements enable row level security;

do $$
declare t text;
begin
  foreach t in array array['profiles','shops','products','variations','upload_batches',
                           'orders','order_items','stock_movements'] loop
    execute format('drop policy if exists baca_semua on %I', t);
    execute format('drop policy if exists tulis_kepala on %I', t);
    execute format('drop policy if exists tulis_admin on %I', t);
  end loop;
end $$;

-- semua peran boleh MEMBACA tabel operasional (harga disembunyikan lewat view)
create policy baca_semua on shops           for select to authenticated using (true);
create policy baca_semua on products        for select to authenticated using (true);
create policy baca_semua on variations      for select to authenticated using (true);
create policy baca_semua on orders          for select to authenticated using (true);
create policy baca_semua on order_items     for select to authenticated using (true);
create policy baca_semua on upload_batches  for select to authenticated using (true);
create policy baca_semua on stock_movements for select to authenticated using (true);
create policy baca_semua on profiles        for select to authenticated using (user_id = auth.uid() or is_kepala());

-- hanya Kepala Admin yang boleh mengubah master & harga
create policy tulis_kepala on shops      for all to authenticated using (is_kepala()) with check (is_kepala());
create policy tulis_kepala on products   for all to authenticated using (is_kepala()) with check (is_kepala());
create policy tulis_kepala on variations for all to authenticated using (is_kepala()) with check (is_kepala());
create policy tulis_kepala on profiles   for all to authenticated using (is_kepala()) with check (is_kepala());

-- Admin Harian mengelola batch & pesanan
create policy tulis_admin on upload_batches for all to authenticated
  using (my_role() in ('admin','kepala')) with check (my_role() in ('admin','kepala'));
create policy tulis_admin on orders for all to authenticated
  using (my_role() in ('admin','kepala')) with check (my_role() in ('admin','kepala'));
create policy tulis_admin on order_items for all to authenticated
  using (my_role() in ('admin','kepala')) with check (my_role() in ('admin','kepala'));

-- buku besar hanya boleh ditulis lewat fungsi (security definer), tidak langsung
revoke insert, update, delete on stock_movements from authenticated;

grant select on v_stock, v_stock_nilai, v_sku_ganda to authenticated;
grant execute on function my_role(), is_kepala(), norm(text), shop_from_sender(text) to authenticated;
grant execute on function resolve_variation(text,text,text,text) to authenticated;
grant execute on function resolve_batch(uuid)                    to authenticated;
grant execute on function scan_out(text,text,text)               to authenticated;
grant execute on function undo_scan(text,text)                   to authenticated;
grant execute on function stock_in(text,integer,text,text,text,text,text) to authenticated;
grant execute on function confirm_batch(uuid,text)               to authenticated;
grant execute on function set_role_pin(text,text)                to authenticated;

-- ============================================================================
-- 11. PEMBERSIHAN OTOMATIS — riwayat lebih dari 1 tahun dibuang
--     Aktifkan dulu: Database → Extensions → pg_cron
-- ============================================================================

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
  return jsonb_build_object('gerakan', a, 'baris_pesanan', b, 'pesanan', c);
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
