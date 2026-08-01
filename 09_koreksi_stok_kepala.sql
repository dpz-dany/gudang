-- ============================================================
-- v9 - koreksi stok langsung oleh Kepala Admin
-- Jalankan setelah 08_harga_kepala.sql. Aman dijalankan ulang.
-- ============================================================

create or replace function kepala_koreksi_stok(
  p_variation_id text,
  p_stok_baru integer,
  p_catatan text default null,
  p_operator text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  sh text;
  sk text;
  stok_lama integer;
  selisih integer;
begin
  if auth.uid() is null or not is_kepala() then
    return jsonb_build_object('ok', false, 'code', 'tidak_berwenang');
  end if;

  if p_stok_baru is null or p_stok_baru < 0 then
    return jsonb_build_object('ok', false, 'code', 'stok_tidak_valid');
  end if;

  select v.shop_id, v.sku, v.stock_on_hand
    into sh, sk, stok_lama
    from variations v
   where v.variation_id = p_variation_id
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'sku_tidak_ada');
  end if;

  selisih := p_stok_baru - stok_lama;
  if selisih = 0 then
    return jsonb_build_object(
      'ok', true, 'berubah', false, 'variation_id', p_variation_id,
      'sku', sk, 'stok_lama', stok_lama, 'selisih', 0, 'sisa', stok_lama
    );
  end if;

  update variations
     set stock_on_hand = p_stok_baru,
         updated_at = now()
   where variation_id = p_variation_id;

  insert into stock_movements (
    shop_id, variation_id, sku, delta, balance_after,
    reason, ref, note, operator
  ) values (
    sh, p_variation_id, sk, selisih, p_stok_baru,
    'opname', 'koreksi-kepala',
    concat_ws(' | ', nullif(trim(p_catatan), ''),
      'hitung fisik ' || p_stok_baru || ' (sistem ' || stok_lama || ')'),
    coalesce(nullif(trim(p_operator), ''), 'kepala')
  );

  return jsonb_build_object(
    'ok', true, 'berubah', true, 'variation_id', p_variation_id,
    'sku', sk, 'stok_lama', stok_lama, 'selisih', selisih, 'sisa', p_stok_baru
  );
end $$;

revoke all on function kepala_koreksi_stok(text,integer,text,text)
  from public, anon, authenticated;
grant execute on function kepala_koreksi_stok(text,integer,text,text)
  to authenticated;

notify pgrst, 'reload schema';
