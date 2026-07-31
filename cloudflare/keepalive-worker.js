// Cloudflare Worker: menjaga proyek Supabase Free tetap aktif.
// Simpan SUPABASE_URL dan SUPABASE_ANON sebagai Secrets di dashboard Cloudflare.

async function pingSupabase(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON) {
    throw new Error('Secret SUPABASE_URL atau SUPABASE_ANON belum diisi.');
  }

  const url = new URL('/rest/v1/shops?select=shop_id&limit=1', env.SUPABASE_URL);
  const response = await fetch(url, {
    headers: {
      apikey: env.SUPABASE_ANON,
      Authorization: `Bearer ${env.SUPABASE_ANON}`,
    },
  });

  // 200 berarti query berhasil; 401 tetap membuktikan proyek merespons.
  if (response.status !== 200 && response.status !== 401) {
    const body = await response.text();
    throw new Error(`Supabase mengembalikan HTTP ${response.status}: ${body.slice(0, 300)}`);
  }

  return `Supabase aktif (HTTP ${response.status})`;
}

export default {
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(pingSupabase(env));
  },

  // Worker tidak menyediakan endpoint publik. Tugasnya hanya berjalan menurut jadwal.
  async fetch() {
    return new Response('Not found', { status: 404 });
  },
};
