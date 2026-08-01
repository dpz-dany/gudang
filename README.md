# Sistem Gudang v9 — developer setup

Multi-shop Shopee stock system. Three role-gated pages, Supabase for live data, GitHub Pages for hosting and product photos.

**This file is for you (the developer). `PANDUAN.md` is the Bahasa guide for your staff.**

---

## What changed from v1, and why

| | v1 | v2 |
|---|---|---|
| Shops | one, hardcoded | any number; shop auto-detected from `Pengirim` on the label, Admin confirms |
| Label reading | broke on your real files | reads wrapped SKUs, multi-item labels, and orders split across two pages |
| Missing SKU | fatal | falls back to product name + variation matching, then Admin Fix |
| Pages | one file, everyone sees everything | four pages, PIN-gated, enforced by database policies |
| Offline | none | scan queue with idempotency; packing never stops |
| Prices | visible to all | Head Admin only, enforced server-side |

### The parser findings you should act on

I tested against `bulkorder.pdf` and `dailyupload.pdf`:

- `bulkorder.pdf` is **one shipment, 10 items, spilling onto page 2.** The continuation page has no label header at all — its identity comes from the `Pesan: (order) (resi)` footer. v2 stitches them into a single order and verifies the line numbers run 1…n with no gaps.
- SKUs wrap mid-cell (`BAUT-CR-` + `PCS`). They always break at a hyphen, so fragments are joined with no separator. All 10 SKUs matched your master exactly.
- The rotated tracking-number strips down the label's sides interleave into the extracted text and corrupted everything in v1. v2 drops any text item whose transform shows rotation.
- **`dailyupload.pdf` has an empty SKU column on all 5 labels.** Not a parser bug — Shopee printed nothing because those listings have no SKU. Name+variation matching rescued 4 of the 5; the fifth (`X-PRO HUB Freehub Thru Axle…`) is a listing whose name isn't in your master at all.

Set SKUs on those listings in Shopee. Everything else is a workaround.

---

## Setup

### 1 · Database

Supabase → **New project** (Singapore region). Then SQL Editor → New query:

1. Jalankan SQL secara berurutan: **`01_schema.sql`**, **`02_akun_dan_toko.sql`**, **`03_patch.sql`**, **`04_patch.sql`**, **`05_edit_sku.sql`**, **`06_sku_induk_dan_persetujuan.sql`**, **`07_persetujuan_stok_dan_keamanan.sql`**, **`08_harga_kepala.sql`**, lalu **`09_koreksi_stok_kepala.sql`**.
2. Database → Extensions → pastikan **`pg_cron`** aktif. Patch v7 mendaftarkan purge bulanan untuk catatan operasional yang berumur lebih dari satu tahun.
3. Authentication → Users → Add user ×3 (tick *Auto Confirm User*):
   - `admin@gudang.local` — password is the Admin Harian PIN
   - `gudang@gudang.local` — password is the Gudang PIN
   - `kepala@gudang.local` — password is the Kepala Admin PIN

   Supabase requires ≥6 characters at creation. Use 6 digits now; the Head Admin page can set 4-digit PINs afterwards.
4. Pastikan ketiga akun sudah dipetakan ke perannya di tabel `profiles`.

### 2 · Hosting

Repository ini **Public** agar GitHub Pages dapat berjalan pada paket GitHub Free. Jangan simpan PIN, `service_role`, atau secret lain di repository; keamanan data tetap ditegakkan oleh login dan RLS Supabase. Sumber situs diterbitkan dari branch `main`, folder `/ (root)`.

```
index.html  admin.html  gudang.html  kepala.html  config.js  sw.js
assets/app.css  assets/core.js  assets/parser.js
img/                       ← product photos
.github/workflows/keepalive.yml
```

Settings → Pages → Source **Deploy from a branch** → `main` / `/ (root)`.
Your URL: `https://<username>.github.io/<repo>/`

### 3 · Point the app at the database

Edit **`config.js`** in GitHub (pencil icon → Commit):

```js
SUPABASE_URL : 'https://xxxxxxxx.supabase.co',
SUPABASE_ANON: 'eyJhbGciOi…'
```

Both from Project Settings → API. Publishable/anon key memang dipakai oleh browser dan dibatasi RLS. Jangan pernah menaruh `service_role`/secret key di repository.

### 4 · Keep-alive

Repo → Settings → Secrets and variables → Actions → New repository secret:

- `SUPABASE_URL` = your project URL
- `SUPABASE_ANON` = your anon key

The workflow runs every 3 days: it pings Supabase (free projects sleep after ~7 idle days) and commits a line to `.keepalive/log.txt`. That second part matters — GitHub disables scheduled workflows after 60 days with no repo activity, so the job keeps itself alive too. Run it once manually from the Actions tab to confirm it's green.

### 5 · Load your products

Open `kepala.html` → Pengaturan → **Impor master produk**, drop in `mass_update_sales_info…xlsx`.

Stock lands at 0 and **prices land empty**, as you asked. Fill prices in the *Harga & Nilai* tab — type and tab out, saves automatically.

Then Ringkasan → **Jalankan pemeriksaan**. On your current data it will flag 4 duplicate SKUs (`CLAMP-LP-41-*` used on two listings) and any order lines that would be rejected at the scanner.

---

## Product photos on GitHub

1. In your repo, click **Add file → Create new file**. Type `img/.gitkeep` in the name box — typing the `/` creates the folder. Commit.
2. In `kepala.html` → **Produk & Foto**, type the SKU, pick any photo. The page crops it square, resizes to 400×400 WebP (~20–40 KB), and names it `<SKU>.webp`. Download it.
3. Repo → `img` folder → **Add file → Upload files** → drag them in → Commit. You can drop hundreds at once.
4. The filename goes in the SKU's *Nama file foto* field. Photos are optional — boxes show 📦 without them.

No GitHub token ever touches the page, which is why this is a download-then-upload step rather than a direct push.

---

## How the security actually works

The PIN screen is convenience. The enforcement is in Postgres:

- Every table has RLS on. The anon key alone reads nothing.
- `my_role()` reads the signed-in user's row in `profiles`.
- Prices live in `v_stock_nilai`, whose `WHERE is_kepala()` returns **zero rows** for Admin and Gudang. Opening DevTools on the warehouse tablet does not reveal prices.
- `stock_movements` has INSERT/UPDATE/DELETE revoked from `authenticated`. The ledger can only be written through the `SECURITY DEFINER` functions, so nobody can forge or erase history from the browser.
- `scan_out` refuses non-`gudang`/`kepala`; `confirm_batch` refuses non-`admin`/`kepala`; opname refuses non-`kepala`. Verified by test.

**Residual risks, stated plainly:**

- Anyone who learns the Gudang PIN gets the Gudang role from any browser. There's no device binding. Rotate PINs when staff leave — that's the Pengaturan tab.
- A public repo means the page source and your Supabase URL are public. That's expected and safe given RLS, but don't commit anything else to that repo.
- `set_role_pin` writes a bcrypt hash straight into `auth.users`. It works because that's what GoTrue uses. If Supabase ever changes its hashing, that one function breaks (login still works; you'd change PINs from the dashboard instead).

---

## Offline behaviour

You chose queue-and-sync. Concretely:

- The service worker caches the page shell, so the tab keeps working with no signal.
- A scan while offline goes into `localStorage` with a unique client ID and shows an orange "Disimpan (luring)" card.
- When the connection returns, the queue flushes automatically.
- Each scan writes ledger rows keyed `<client_id>:<line_id>`. On re-sync, `scan_out` checks that prefix and returns `sudah_tersinkron` without touching stock. **This was a real bug I found and fixed** — the guard originally compared against the wrong key, so a re-sync crashed on a unique-constraint violation instead of returning cleanly.
- If a queued scan is rejected at sync time (someone else already packed it), the operator gets a warning and it's logged for Head Admin.

The oversell window you accepted: two devices offline, both scanning orders that draw the same SKU, and stock only goes negative once both sync. The Head Admin sees it as negative stock with an alert on the Ringkasan tab.

---

## Storage — will Supabase hold a year?

Free tier is 500 MB. Rough sizing at 200 orders/day, ~1.6 lines each:

| Table | Rows/year | Bytes/row | Total |
|---|---|---|---|
| `orders` | 73,000 | ~180 | ~13 MB |
| `order_items` | 117,000 | ~260 | ~30 MB |
| `stock_movements` | 117,000 | ~150 | ~18 MB |
| products + variations | ~1,000 | ~300 | <1 MB |

**≈ 60 MB plus indexes — call it 100 MB for a full year.** Comfortably inside the free tier even at double your volume. `purge_riwayat_lama()` runs on the 1st of each month and drops anything past 12 months, so it plateaus rather than grows forever.

---

## Verified

Against a real Postgres and a real headless browser, not by inspection:

- Schema applies clean from scratch; all functions compile.
- Role enforcement: Gudang blocked from `confirm_batch` and opname; Admin blocked from `scan_out`; both see 0 rows of price data; Kepala sees all 609.
- The 10-item two-page order deducts all 10 lines correctly; a second scan is refused; undo restores exactly; re-sync with the same client ID is a no-op.
- An order with one unresolvable line deducts **nothing** — verified the other line's stock was untouched.
- Admin Fix: label read 1, admin added +3, scanner deducted 4.
- Parser: 4 different PDFs including your two real ones.
- Browser: PIN gate, PDF import (6 orders / 15 lines / shop auto-detected), the 25% alert firing at 33%, scan results with negative stock and FIX marks, order boxes turning green, SKU aggregation, offline queue, grid/list toggle, live price totals.

Two bugs found and fixed during testing: the offline idempotency key mismatch above, and an unbounded pagination loop in the stock loader.

---

## Not built

- Automatic stock push back to Shopee (needs Shopee Open API approval — separate project)
- Barcode labels for your own shelves
- WhatsApp/email low-stock alerts
- Per-user accounts within a role (currently one shared account per role)


---
---

# v3 — apa yang baru (baca ini dulu)

Run `03_patch.sql` after `01_schema.sql` and `02_akun_dan_toko.sql`. It is additive and safe to re-run. `config.js` already has your Supabase URL and publishable key.

## 1. TikTok / Tokopedia labels

Your TikTok label is a completely different animal from Shopee's:

| | Shopee | TikTok (J&T) |
|---|---|---|
| Columns | `#` · Nama Produk · SKU · Variasi · Qty | Product Name · **SKU** · **Seller SKU** · Qty |
| Where the real SKU lives | `SKU` column | **`Seller SKU`** column |
| What `SKU` column holds | the SKU | the **variation** (`Hitam`, `Default`) |
| Running number column | yes | **no** |
| Shop identity | `Pengirim: GOWES` | `NickName: deliceangelia` (`Pengirim` is a person) |
| Order number | `No.Pesanan` | `Order Id` |
| Row-count check | none | **`Qty Total: 7`** |

The parser detects the layout from the header row and maps the columns accordingly. Two extra things it does for TikTok:

- **Uses `Qty Total` as a checksum.** If the lines it read don't sum to the printed total, it warns that a page is probably missing. Your file: 2+1+1+1+1+1 = 7 ✓.
- **Handles letter-split text.** J&T prints `Pe ne rima :` as separate glyphs; the field regexes are built to tolerate that.

Your file is one order across two pages with six items and it now reads as a single order. **All six have an empty `Seller SKU`** — same disease as your Shopee listings. Name matching rescued 4 of 6 automatically in my test against your master.

**Setup:** add a shop row for TikTok and put the NickName in `sender_names`, e.g. `{deliceangelia}`. Auto-detect then works the same as Shopee.

## 2. When a SKU isn't recognised — the warehouse is no longer stuck

You said it plainly: the goods go out regardless. So:

- The scan error card now has a **🚚 Lanjut Kirim** button. It asks for a reason, deducts every line it *can* resolve, marks the order packed, and records the rest as a data debt.
- Head Admin gets a **red notification** naming the order, the reason, who did it, which device, what was deducted and what wasn't.
- The **Notifikasi** tab is the new home page for exceptions. The **Pesanan bermasalah** table lists every force-greened order — exactly the "orders that were greened without scanning" view you asked for.

`undo_scan` still exists but is now a small secondary button, not the headline.

## 3. Warehouse can add items to an order

On any scanned order: **➕ Tambah barang**. Search a SKU, pick a quantity, add a note. It deducts immediately (the item is physically going in the box), appends the line to the order, and notifies Head Admin with the SKU, quantity, note and operator. History shows it as `keluar_tambahan` with `ditambahkan Gudang · <note>`.

> **A bug this caught.** My first version deducted on add *and* again when the order was scanned. There is now a `sudah_potong` flag; `scan_out` shows those lines but never deducts them twice. Verified: stock moved once, not twice.

## 4. COD returns — three signatures, in your order

```
Admin Harian          Kepala Admin           Gudang
   ajukan      →         setujui       →      terima          → stok naik
(no stock move)     (no stock move)     (stock moves HERE)
```

- Admin types the order number manually and lists SKUs (tab **Retur COD**). Nothing moves.
- Head Admin sees it under **Persetujuan**. **The approve button is disabled while any SKU is unmatched** — you cannot approve a return into a SKU that doesn't exist.
- Only after approval does it appear on the Gudang **Retur Masuk** tab. Stock rises when the warehouse confirms the box is physically there.
- Every step is timestamped with who did it, and each stage raises a notification.

Verified: warehouse receiving before approval → `belum_disetujui`; admin trying to receive → `tidak_berwenang`; approving with an unmatched SKU → `ada_sku_belum_cocok`; re-syncing a queued receipt → no double stock.

## 5. Opname without stickers

You're right that stickers are pointless on parts smaller than a fingernail. The opname session is pure data:

- Gudang opens **Opname**, names a session, and types physical counts next to the system numbers. Difference shows live.
- Submitting locks the session and sends it to Head Admin.
- Head Admin reviews only the lines with a difference, then approves — **that** is when stock changes, logged as `opname` with `hitung fisik X (sistem Y)`.

A warehouse can no longer silently adjust its own stock, which is the point.

## 6. LCL shipments — the logic

The problem with imports is that one purchase arrives in several drops, so "did it all come?" is unanswerable from a stock number alone. The model separates **expected** from **received**:

```
lcl          one shipment: ref (LCL-2026-08-A), supplier, invoice, ETA, status
lcl_items    what you EXPECT: SKU + qty_harap          ← entered once, by you
movements    what ACTUALLY arrived, each tagged with lcl_id
v_lcl_progres  qty_harap vs SUM(positive movements)  → shortfall per SKU
```

Rules:

1. Head Admin creates the shipment and the expected list. Nothing touches stock.
2. Every goods-in can point at a shipment. Stock rises immediately — the goods are on the floor.
3. Progress is computed, never stored, so partial arrivals just accumulate. My test: 60 then 40 against an expected 100 → `100/100`, while a second SKU sits at `0/50`.
4. Received > expected is allowed and shows as over-delivery rather than being blocked — suppliers do overship, and refusing the entry would make the stock number wrong.
5. Goods-in with no shipment reference still works exactly as before.

The one thing this does *not* do is tell you an LCL is late — that needs the ETA to be watched. Say the word and I'll add an alert when a shipment passes its ETA with a shortfall.

## 7. The three mandatory fixes

I read this as the three "Residual risks" in the v2 README. If you meant something else, tell me and I'll redo them.

**(a) A PIN is a shared secret with no device binding.** Every scan, goods-in and force-send now records a device ID. Head Admin sees every device, names it, and can flip **Kunci perangkat** on — after which only approved devices can scan, refused in the database, not the browser. Off by default, and the UI warns you if you switch it on with nothing approved yet.

**(b) Public repo.** Keputusan deployment saat ini adalah repository Public supaya GitHub Pages gratis dapat aktif. Hanya publishable/anon key yang boleh berada di kode browser; `service_role`, PIN, dan secret lain dilarang masuk repository.

**(c) `set_role_pin` writes bcrypt into `auth.users` and could break silently.** It now verifies the new hash actually validates the new PIN and **rolls back to the old password** if not, returning `gagal_diverifikasi` instead of locking you out. It also rejects `1234`, `0000`, and all-same-digit PINs.

## 8. Deploying on Cloudflare Pages

1. Push these files to a **private** GitHub repo (no `.sql` files needed on the site).
2. [dash.cloudflare.com](https://dash.cloudflare.com) → **Workers & Pages** → **Create** → **Pages** → **Connect to Git** → authorise GitHub → pick the repo.
3. Build settings — this is a plain static site, so leave everything empty:
   - Framework preset: **None**
   - Build command: *(blank)*
   - Build output directory: `/`
4. **Save and Deploy.** You get `https://<project>.pages.dev` in about a minute. Every push redeploys automatically.
5. Optional custom domain: **Custom domains** → **Set up a domain**.
6. Optional but recommended for a warehouse tool — **Settings → General → Access policy** restricts the site to email addresses you list, adding a second lock in front of the PIN screen. Free for up to 50 users.

Keep the GitHub Action for the Supabase keep-alive; Cloudflare doesn't sleep, but Supabase still does.

**Supabase must know the new origin:** Authentication → URL Configuration → add `https://<project>.pages.dev` to **Site URL / Redirect URLs**.

## 9. Notes on your Supabase keys

`sb_publishable_…` is the new-format publishable key — safe in a public file by design, which is why `config.js` carries it. The client library is pinned to `@supabase/supabase-js@2.111.0`, which understands that format. **Never put the `sb_secret_…` / `service_role` key in any of these files** — that one bypasses every policy in the schema.

## 10. Verified in v3

- Parser: all five PDFs, both platforms, no regression on the Shopee files.
- Patch applies clean on a fresh database and again on top of itself.
- Force-send, warehouse add, three-stage return, opname session, LCL progress, device lock, PIN validation and rollback — each exercised against real Postgres with role switching.
- All four pages driven in headless Chrome, including the TikTok PDF import end to end.
- Two bugs found and fixed this round: the double deduction on warehouse-added items, and the `Pengirim` regex losing shop detection after the letter-split fix (needed a multiline flag).


---
---

# v4 — jawaban untuk label tanpa SKU

Run `04_patch.sql` after `03_patch.sql`. Additive, safe to re-run.

## Your question, answered directly

**No, an SKU-less label is not a problem any more — but not for the reason I assumed in v3.**

Your new label (`0731_184110`) has `Seller SKU = BAUT-CR-PCS` filled in, and it reads perfectly: 1 order, 4 units, `Qty Total: 4` matches. When TikTok prints the SKU, everything just works.

Testing that label against your real master turned up something more serious than the empty-SKU case, though.

### TikTok prints a SHORTENED product name

| | |
|---|---|
| On the label | `Baut Chainring Single Per Pcs` |
| In your catalogue | `Baut Chainring Sepeda Roadbbike Seli MTB Single Aluminium Alloy Harga Per Pcs` |

They are not the same string, and they never will be. So my v3 "match by product name" fallback — the thing that was supposed to rescue SKU-less lines — **cannot work on TikTok at all**. It only worked on the Shopee files because Shopee prints the full catalogue name.

That means: if a TikTok listing has no Seller SKU, v3 had *no* way to identify the item. Guessing harder is not the answer; a wrong guess silently deducts the wrong stock.

### The fix: a translation book you teach once

`alias_produk` maps *what the label says* → *which SKU it is*. Head Admin makes that call once, and it is permanent.

The Notifikasi tab now opens with **"SKU belum cocok — petakan sekali, beres selamanya"**. Each stuck item shows the label text, the variation, how many orders and units are blocked, and a **🔗 Petakan ke SKU** button. The dialog proposes candidates ranked by word overlap, with a bonus when the variation matches or contains the label's variation. Tested on your real data:

| Stuck line | Top suggestion | Score |
|---|---|---|
| `Baut Chainring Single Per Pcs` | **BAUT-CR-PCS** | 1.000 |
| `X-PRO HUB … / QR Merah Belakang` | **HUB-XPRO-32H-MRH-BLKG** (Merah Belakang) | 1.350 |

Both correct, first hit. You click **Pilih**, confirm, and:

1. The mapping is saved permanently.
2. Every pending order line blocked by that item is re-resolved **immediately** — verified: one save unstuck the waiting line in the same call.
3. Any `sku_tidak_dikenal` notification for orders that are now fully resolved closes itself.
4. Every future label with that name matches automatically, with method `alias`.

You never have to touch the TikTok or Shopee catalogue for this. Fixing the Seller SKU upstream is still better housekeeping, but it is no longer a blocker.

Review or remove mappings under **Pengaturan → Buku terjemahan nama produk**. It is deliberately **excluded from the 1-year purge** — the translation book must outlive the order history.

## Two smaller fixes in the same patch

**`Default` is not a variation.** TikTok writes `Default` for products with no variants; the matcher was treating it as a real variation name and failing. `Default`, `-` and blank are now all read as "no variation".

**Prefix matching.** If the label name is an exact prefix of one — and only one — catalogue name, that now matches automatically (`awalan nama`). Cheap win that catches truncation without guessing.

## A gap you should know about

**TikTok labels do not always print `NickName`.** Your first TikTok file had `NickName: deliceangelia`; this one has none, so the only sender identity is `Pengirim: EVANO DANY` — a person, not a shop.

Shop auto-detect now tries **NickName, then Pengirim, then whatever it settled on**, and the import screen tells you which name it matched (`Toko (terdeteksi dari "EVANO DANY")`). When nothing matches, it now says so and lists the names it saw, so you know exactly what to add.

**Do this once:** Kepala Admin → Pengaturan → Toko → put both `deliceangelia` and `EVANO DANY` in the sender-names field for the TikTok shop. After that, detection is automatic for both label styles.

## Order of matching, final

```
0  buku terjemahan (alias)      ← human decision, beats every guess
1  SKU exact
2  SKU + variation              (when one SKU is reused)
3  parent SKU + variation
4  catalogue name + variation
5  catalogue name, single variation only
6  label name is a prefix of exactly one catalogue name
   otherwise → rejected, and it lands in "petakan ke SKU"
```

Nothing is ever guessed between two plausible candidates. If it is ambiguous, it stops and asks you — that is the whole design.

## Verified in v4

- The new label parses to 1 order / 4 units, `Qty Total` checksum passes.
- Patch applies clean and again on top of itself.
- `Default` handling, prefix matching, alias precedence, suggestion ranking, save-then-auto-unstick, and notification auto-close — all against real Postgres with your 609-SKU master.
- Browser: import of the new TikTok label, shop detected from `EVANO DANY`, the not-detected warning, the mapping dialog with real suggestions, manual search fallback, and the translation-book table.
- One bug found and fixed: the notification badge threw `Assignment to constant variable` after I made it include unmatched lines.

---

# v6 — SKU Induk, foto tunggal, dan persetujuan Gudang

Jalankan **`06_sku_induk_dan_persetujuan.sql`** setelah patch v5. Patch ini aman dijalankan ulang.

- Tampilan stok Gudang dan Kepala Admin sekarang dikelompokkan menjadi **SKU Induk**. Klik SKU Induk untuk melihat tipe/variasi dan stok masing-masing.
- Foto hanya ada di `products.image_url`: satu foto untuk semua variasi dalam SKU Induk. Jika tidak ada nama file khusus, aplikasi mencari `img/<SKU-INDUK>.jpg`.
- Gudang dapat mengajukan perubahan nama produk, nama tipe, atau SKU variasi. Usulan disimpan ke Supabase, lalu Kepala Admin menyetujui atau menolak di tab **Persetujuan**.
- Redirect sesi lama browser dimatikan untuk testing. Kepala Admin dapat mengaktifkannya nanti di **Pengaturan → Perilaku login**; statusnya disimpan di Supabase.
- Pembersihan bulanan sekarang mencakup seluruh riwayat operasional lebih dari satu tahun: gerakan stok, pesanan, batch, notifikasi, retur, opname, LCL yang tidak lagi dirujuk, pengajuan master, dan perangkat tidak aktif. Master produk dan buku terjemahan tidak dihapus.

## Foto SKU Induk

Gunakan satu file bernama persis seperti SKU Induk, misalnya `HUB-XPRO-32H.jpg`, di folder `img/`. File ekspor yang dipakai saat audit ini memiliki 163 SKU Induk dan seluruh 163 foto sudah dinormalkan ke nama tersebut.

---

# v7 — persetujuan stok masuk dan penguatan keamanan

Jalankan **`07_persetujuan_stok_dan_keamanan.sql`** setelah patch v6. Patch ini aman dijalankan ulang.

- Gudang tidak dapat lagi mengubah stok aktual melalui `stock_in`. Tombol stok masuk memanggil `ajukan_stok_masuk`, lalu menyimpan jumlah, petugas, perangkat, catatan, dan snapshot stok ke `pengajuan_stok_masuk`.
- Kepala Admin menyetujui atau menolak dari tab **Persetujuan**. Persetujuan mengubah stok dan menulis `stock_movements` dalam satu transaksi; klik ulang ditolak agar stok tidak pernah bertambah dua kali.
- Tampilan Gudang langsung menunjukkan label `+… menunggu`, tetapi angka stok aktual tetap terpisah sampai disetujui.
- Fungsi purge lebih dari satu tahun hanya dapat dijalankan oleh pemilik database/cron. Akses `anon` dan `authenticated` dicabut, dan view nilai stok memakai `security_invoker=on`.
- Jadwal `pg_cron` berjalan setiap tanggal 1 pukul 03:00 UTC dan membersihkan riwayat operasional, termasuk pengajuan stok. Master SKU, akun, toko, pengaturan, dan buku terjemahan tetap disimpan.

# v8 — akses Harga & Nilai Kepala Admin

Jalankan **`08_harga_kepala.sql`** setelah patch v7. Patch ini aman dijalankan ulang.

- Menu **Harga & Nilai** membaca dan menyimpan harga melalui fungsi khusus Kepala Admin, sehingga tidak lagi gagal dengan pesan `permission denied for table variations`.
- Kolom `price` tidak diberikan kepada sesi biasa. Admin Harian dan Gudang tetap hanya dapat membaca kolom operasional tanpa harga.
- Nilai stok nol ditampilkan jelas sebagai **Rp 0**, bukan tanda kosong.

# v9 — koreksi stok Kepala Admin

Jalankan **`09_koreksi_stok_kepala.sql`** setelah patch v8. Patch ini aman dijalankan ulang.

- Koreksi stok Kepala memakai fungsi khusus `kepala_koreksi_stok`, bukan lagi fungsi umum stok masuk.
- Nilai baru divalidasi sebagai bilangan bulat 0 atau lebih, dikunci dalam transaksi, dan dicatat sebagai `opname` di riwayat stok.
- Dialog menampilkan stok lama, stok baru, dan selisih sebelum Kepala mengonfirmasi penyimpanan.
