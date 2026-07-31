# Keepalive Supabase melalui Cloudflare Worker

Gunakan Worker ini jika website diunggah langsung ke Cloudflare Pages tanpa GitHub.
Worker hanya mengirim query ringan ke Supabase tiap 3 hari. Cloudflare Pages sendiri
tidak membutuhkan keepalive.

## Pasang dari dashboard Cloudflare

1. Buka **Workers & Pages** → **Create** → **Create Worker**.
2. Beri nama `gudang-keepalive` → **Deploy**.
3. Buka **Edit code**, ganti seluruh kode dengan isi `keepalive-worker.js`, lalu **Deploy**.
4. Buka **Settings** → **Variables and Secrets** → **Add**. Tambahkan dua item bertipe
   **Secret**:
   - `SUPABASE_URL`: alamat proyek Supabase, misalnya `https://xxxx.supabase.co`
   - `SUPABASE_ANON`: publishable/anon key dari Supabase Project Settings → API
5. Klik **Deploy** setelah kedua secret tersimpan.
6. Buka **Settings** → **Triggers** → **Cron Triggers** → **Add Cron Trigger**.
   Isi: `17 2 */3 * *`.

Cron memakai waktu UTC: jadwal tersebut berjalan setiap tiga hari pukul 09.17 WIB.
Anda dapat memeriksa hasilnya di **Settings** → **Trigger Events** → **View events**.

Jangan menaruh nilai secret di kode Worker atau file yang diunggah ke Pages.
`config.js` aplikasi memang berisi publishable/anon key; key itu berbeda dari secret
dan aman dipakai oleh browser selama kebijakan RLS Supabase tetap aktif.
