-- ============================================================================
--  PATCH v4  —  jalankan SETELAH 03_patch.sql. Aman diulang.
--
--  Masalah yang diselesaikan:
--   Label TikTok mencetak NAMA PENDEK, bukan nama katalog.
--     label  : "Baut Chainring Single Per Pcs"
--     katalog: "Baut Chainring Sepeda Roadbbike Seli MTB Single Aluminium
--               Alloy Harga Per Pcs"
--   Jadi kalau kolom Seller SKU kosong, pencocokan lewat nama SELALU gagal.
--
--  Jawabannya: buku terjemahan. Kepala Admin memetakan
--  "nama di label + variasi" → SKU satu kali. Setelah itu label serupa
--  cocok sendiri selamanya, tanpa perlu mengubah apa pun di TikTok/Shopee.
-- ============================================================================

create table if not exists alias_produk (
  id           bigserial primary key,
  shop_id      text references shops(shop_id) on delete cascade,
  nama_norm    text not null,          -- nama di label, dinormalkan
  variasi_norm text not null default '',
  produk_asli  text,                   -- apa adanya, untuk ditampilkan
  variasi_asli text,
  variation_id text references variations(variation_id) on delete cascade,
  dipakai      integer not null default 0,
  dibuat_oleh  text,
  dibuat_pada  timestamptz default now(),
  unique (shop_id, nama_norm, variasi_norm)
);
create index if not exists alias_cari_idx on alias_produk (shop_id, nama_norm);

-- ============================================================================
--  Pencocokan versi baru
--   0. buku terjemahan (keputusan manusia — menang atas semua tebakan)
--   1. SKU persis · 2 SKU+variasi · 3 SKU induk+variasi
--   4. nama katalog persis + variasi · 5 nama katalog persis (1 variasi saja)
--   6. nama label adalah AWALAN nama katalog (TikTok memendekkan nama)
--  "Default" dan "-" dianggap tidak ada variasi.
-- ============================================================================

create or replace function resolve_variation(
  p_shop text, p_sku text, p_variation text default null, p_product text default null)
returns table (variation_id text, method text, matches integer)
language plpgsql stable as $$
declare n integer; v text;
begin
  -- TikTok menulis "Default" untuk produk tanpa variasi
  if norm(p_variation) in ('default','-','') then p_variation := null; end if;

  -- ---- 0. buku terjemahan ----
  if coalesce(trim(p_product),'') <> '' then
    select a.variation_id into v from alias_produk a
     where a.shop_id = p_shop
       and a.nama_norm = norm(p_product)
       and a.variasi_norm = norm(coalesce(p_variation,''))
     limit 1;
    if v is not null then
      return query select v, 'alias', 1; return;
    end if;
  end if;

  -- ---- 1..3 lewat SKU ----
  if coalesce(trim(p_sku),'') <> '' then
    select count(*) into n from variations x
     where x.active and x.shop_id = p_shop and norm(x.sku) = norm(p_sku);

    if n = 1 then
      return query select x.variation_id, 'sku', 1 from variations x
       where x.active and x.shop_id = p_shop and norm(x.sku) = norm(p_sku); return;
    end if;

    if n > 1 and p_variation is not null then
      select count(*) into n from variations x
       where x.active and x.shop_id = p_shop and norm(x.sku) = norm(p_sku)
         and norm(x.variation_name) = norm(p_variation);
      if n = 1 then
        return query select x.variation_id, 'sku+variasi', 1 from variations x
         where x.active and x.shop_id = p_shop and norm(x.sku) = norm(p_sku)
           and norm(x.variation_name) = norm(p_variation); return;
      end if;
      return query select null::text, 'sku ganda', n; return;
    end if;
    if n > 1 then return query select null::text, 'sku ganda', n; return; end if;

    if p_variation is not null then
      select count(*) into n from variations x
       where x.active and x.shop_id = p_shop and norm(x.parent_sku) = norm(p_sku)
         and norm(x.variation_name) = norm(p_variation);
      if n = 1 then
        return query select x.variation_id, 'induk+variasi', 1 from variations x
         where x.active and x.shop_id = p_shop and norm(x.parent_sku) = norm(p_sku)
           and norm(x.variation_name) = norm(p_variation); return;
      end if;
    end if;
  end if;

  -- ---- 4..6 lewat nama produk ----
  if coalesce(trim(p_product),'') <> '' then
    if p_variation is not null then
      select count(*) into n from variations x join products p on p.product_id = x.product_id
       where x.active and x.shop_id = p_shop
         and norm(p.product_name) = norm(p_product)
         and norm(x.variation_name) = norm(p_variation);
      if n = 1 then
        return query select x.variation_id, 'nama+variasi', 1
          from variations x join products p on p.product_id = x.product_id
         where x.active and x.shop_id = p_shop
           and norm(p.product_name) = norm(p_product)
           and norm(x.variation_name) = norm(p_variation); return;
      end if;
    end if;

    select count(*) into n from variations x join products p on p.product_id = x.product_id
     where x.active and x.shop_id = p_shop and norm(p.product_name) = norm(p_product);
    if n = 1 then
      return query select x.variation_id, 'nama', 1
        from variations x join products p on p.product_id = x.product_id
       where x.active and x.shop_id = p_shop and norm(p.product_name) = norm(p_product); return;
    end if;
    if n > 1 then return query select null::text, 'nama ganda', n; return; end if;

    -- nama di label adalah awalan nama katalog, dan hanya satu produk yang cocok
    if length(norm(p_product)) >= 12 then
      select count(*) into n from variations x join products p on p.product_id = x.product_id
       where x.active and x.shop_id = p_shop and norm(p.product_name) like norm(p_product) || '%';
      if n = 1 then
        return query select x.variation_id, 'awalan nama', 1
          from variations x join products p on p.product_id = x.product_id
         where x.active and x.shop_id = p_shop
           and norm(p.product_name) like norm(p_product) || '%'; return;
      end if;
    end if;
  end if;

  return query select null::text, 'tidak ditemukan', 0;
end $$;

-- ============================================================================
--  Usulan padanan: dipakai layar "Petakan ke SKU" supaya Kepala Admin
--  tinggal menekan, bukan mencari sendiri di 609 SKU.
-- ============================================================================

create or replace function alias_saran(p_shop text, p_produk text, p_variasi text default null)
returns table (variation_id text, sku text, product_name text, variation_name text,
               stok integer, skor numeric)
language plpgsql stable security definer set search_path = public as $$
declare kata text[];
begin
  select array(
    select w from unnest(regexp_split_to_array(
      lower(regexp_replace(coalesce(p_produk,''), '[^a-zA-Z0-9]+', ' ', 'g')), '\s+')) w
     where length(w) >= 3) into kata;

  return query
  select x.variation_id, x.sku, p.product_name, x.variation_name, x.stock_on_hand,
         round(
           ( (select count(*) from unnest(kata) w where lower(p.product_name) like '%' || w || '%')::numeric
             / greatest(1, coalesce(array_length(kata,1),1)) )
           + case
               when p_variasi is null or coalesce(x.variation_name,'') = '' then 0
               when norm(x.variation_name) = norm(p_variasi) then 0.5
               -- label sering menambah kata di depan ("QR Merah Belakang"
               -- vs "Merah Belakang"), jadi saling-mengandung tetap dihitung
               when norm(p_variasi) like '%' || norm(x.variation_name) || '%'
                 or norm(x.variation_name) like '%' || norm(p_variasi) || '%' then 0.35
               else 0 end
         , 3)
  from variations x join products p on p.product_id = x.product_id
  where x.active and x.shop_id = p_shop
  order by 6 desc, x.sku
  limit 15;
end $$;

-- ============================================================================
--  Simpan padanan, lalu langsung cocokkan ulang semua pesanan yang macet
-- ============================================================================

create or replace function resolve_pending(p_shop text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare it record; v text; m text; n integer := 0;
begin
  for it in select oi.id, oi.sku_label, oi.variation_name, oi.product_name, o.shop_id
              from order_items oi join orders o on o.order_sn = oi.order_sn
             where oi.variation_id is null and o.status = 'pending'
               and (p_shop is null or o.shop_id = p_shop) loop
    select r.variation_id, r.method into v, m
      from resolve_variation(it.shop_id, it.sku_label, it.variation_name, it.product_name) r;
    if v is not null then
      update order_items set variation_id = v, resolve_method = m where id = it.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function alias_simpan(
  p_shop text, p_produk text, p_variasi text, p_variation_id text, p_oleh text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n integer; sk text;
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  if coalesce(trim(p_produk),'') = '' then
    return jsonb_build_object('ok', false, 'code', 'nama_kosong'); end if;

  select sku into sk from variations where variation_id = p_variation_id;
  if sk is null then return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada'); end if;

  insert into alias_produk (shop_id, nama_norm, variasi_norm, produk_asli, variasi_asli,
                            variation_id, dibuat_oleh)
  values (p_shop, norm(p_produk),
          norm(coalesce(nullif(lower(trim(coalesce(p_variasi,''))),'default'),'')),
          p_produk, p_variasi, p_variation_id, p_oleh)
  on conflict (shop_id, nama_norm, variasi_norm)
    do update set variation_id = excluded.variation_id,
                  produk_asli = excluded.produk_asli,
                  variasi_asli = excluded.variasi_asli,
                  dibuat_oleh = excluded.dibuat_oleh;

  n := resolve_pending(p_shop);

  -- tutup notifikasi "SKU tidak dikenal" untuk pesanan yang sekarang sudah beres
  update notifikasi set status = 'selesai', ditutup_pada = now(), ditutup_oleh = p_oleh,
         catatan = coalesce(catatan,'') || ' · dipetakan ke ' || sk
   where jenis = 'sku_tidak_dikenal' and status <> 'selesai'
     and ref in (select o.order_sn from orders o
                  where o.status = 'pending'
                    and not exists (select 1 from order_items oi
                                     where oi.order_sn = o.order_sn and oi.variation_id is null));

  return jsonb_build_object('ok', true, 'sku', sk, 'baris_ikut_beres', n);
end $$;

create or replace function alias_hapus(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_kepala() then return jsonb_build_object('ok', false, 'code', 'tidak_berwenang'); end if;
  delete from alias_produk where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- daftar baris yang masih macet, digabung supaya satu padanan menyelesaikan banyak
create or replace view v_belum_cocok as
select o.shop_id,
       oi.product_name,
       coalesce(nullif(oi.variation_name,''), '') as variation_name,
       max(oi.sku_label)              as contoh_sku_label,
       count(*)                        as jumlah_baris,
       sum(oi.qty_final)               as jumlah_unit,
       string_agg(distinct o.order_sn, ', ' order by o.order_sn) as pesanan,
       max(o.platform)                 as platform
from order_items oi join orders o on o.order_sn = oi.order_sn
where oi.variation_id is null and o.status = 'pending'
group by o.shop_id, oi.product_name, coalesce(nullif(oi.variation_name,''), '');
alter view v_belum_cocok set (security_invoker = on);

-- ============================================================================
--  Izin
-- ============================================================================

alter table alias_produk enable row level security;
drop policy if exists baca_semua  on alias_produk;
drop policy if exists tulis_kepala on alias_produk;
create policy baca_semua   on alias_produk for select to authenticated using (true);
create policy tulis_kepala on alias_produk for all to authenticated
  using (is_kepala()) with check (is_kepala());

grant select on v_belum_cocok to authenticated;
grant execute on function alias_saran(text,text,text)                to authenticated;
grant execute on function alias_simpan(text,text,text,text,text)     to authenticated;
grant execute on function alias_hapus(bigint)                        to authenticated;
grant execute on function resolve_pending(text)                      to authenticated;
grant execute on function resolve_variation(text,text,text,text)     to authenticated;

-- ikut dibersihkan setahun sekali? TIDAK — buku terjemahan harus abadi.
