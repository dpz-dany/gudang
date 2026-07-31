-- PATCH 08 - Harga & Nilai hanya melalui fungsi Kepala Admin
-- Jalankan sekali setelah 07_persetujuan_stok_dan_keamanan.sql.

begin;

-- Daftar harga tidak lagi membaca view security_invoker. Fungsi ini memakai
-- hak pemilik database, tetapi tetap memeriksa peran aplikasi dari sesi aktif.
create or replace function kepala_daftar_harga(
  p_offset integer default 0,
  p_limit  integer default 1000
)
returns table (
  variation_id   text,
  shop_id        text,
  sku            text,
  product_name   text,
  variation_name text,
  price          numeric,
  stock_on_hand  integer,
  nilai          numeric
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not is_kepala() then
    raise exception 'khusus Kepala Admin' using errcode = '42501';
  end if;

  return query
  select v.variation_id, v.shop_id, v.sku, p.product_name, v.variation_name,
         v.price, v.stock_on_hand, (v.price * v.stock_on_hand) as nilai
    from variations v
    left join products p on p.product_id = v.product_id
   where v.active
   order by v.sku, v.variation_id
   offset greatest(coalesce(p_offset, 0), 0)
   limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
end $$;

-- Simpan satu harga melalui jalur yang sama. Nilai negatif ditolak.
create or replace function kepala_simpan_harga(
  p_variation_id text,
  p_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v variations%rowtype;
begin
  if auth.uid() is null or not is_kepala() then
    raise exception 'khusus Kepala Admin' using errcode = '42501';
  end if;
  if p_price is not null and p_price < 0 then
    return jsonb_build_object('ok', false, 'code', 'harga_negatif');
  end if;

  update variations
     set price = p_price, updated_at = now()
   where variation_id = p_variation_id
   returning * into v;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada');
  end if;

  return jsonb_build_object(
    'ok', true,
    'variation_id', v.variation_id,
    'price', v.price,
    'stock_on_hand', v.stock_on_hand,
    'nilai', case when v.price is null then null else v.price * v.stock_on_hand end
  );
end $$;

revoke all on function kepala_daftar_harga(integer,integer) from public, anon, authenticated;
revoke all on function kepala_simpan_harga(text,numeric) from public, anon, authenticated;
grant execute on function kepala_daftar_harga(integer,integer) to authenticated;
grant execute on function kepala_simpan_harga(text,numeric) to authenticated;

-- Harga tidak boleh dibaca langsung lewat tabel atau view oleh sesi biasa.
-- Kolom operasional lain tetap dapat dipakai Admin Harian dan Gudang.
revoke select on table variations from anon, authenticated;
grant select (
  variation_id, product_id, shop_id, sku, parent_sku, variation_name,
  stock_on_hand, reorder_point, image_url, active, updated_at
) on table variations to authenticated;
revoke select on v_stock_nilai from public, anon, authenticated;

commit;
