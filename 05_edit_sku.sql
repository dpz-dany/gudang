-- ============================================================================
--  PATCH v5 — ubah SKU dari halaman Kepala Admin
--  Jalankan SETELAH 04_patch.sql. Aman dijalankan berulang kali.
--
--  Identitas teknis barang (variation_id) tidak berubah. Karena itu seluruh
--  koneksi stok, pesanan, retur, LCL, opname, dan alias label tetap utuh.
--  Riwayat stok yang lama sengaja menyimpan SKU lama sebagai jejak audit.
-- ============================================================================

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

  -- SKU yang sama masih boleh dipakai beberapa variasi, tetapi bukan variasi
  -- yang sama dua kali pada toko yang sama.
  if exists (
    select 1 from variations v
     where v.shop_id = lama.shop_id and v.variation_id <> lama.variation_id
       and norm(v.sku) = norm(sku_baru)
       and norm(coalesce(v.variation_name,'')) = norm(coalesce(variasi_baru,''))
  ) then
    return jsonb_build_object('ok', false, 'code', 'sku_variasi_sudah_ada');
  end if;

  update products set product_name = nama_baru
   where product_id = lama.product_id;

  -- Bila SKU induk pada produk masih sama dengan nilai lama, ikut perbarui agar
  -- formulir tambah-variasi berikutnya memakai kode induk terbaru.
  update products set parent_sku = induk_baru
   where product_id = lama.product_id
     and parent_sku is not distinct from lama.parent_sku;

  update variations set sku = sku_baru, parent_sku = induk_baru,
         variation_name = variasi_baru, image_url = foto_baru, updated_at = now()
   where variation_id = lama.variation_id;

  return jsonb_build_object('ok', true, 'sku_lama', lama.sku, 'sku', sku_baru);
end $$;

grant execute on function ubah_master_sku(text,text,text,text,text,text) to authenticated;
