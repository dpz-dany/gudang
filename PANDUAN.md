# Panduan Pemakaian — Sistem Gudang

Untuk semua petugas. Simpan alamat halaman ini di layar utama HP/tablet supaya gampang dibuka.

---

## Masuk

Buka alamat sistem → pilih peranmu → ketik PIN. Selesai.

Kalau PIN lupa atau ganti orang, minta **Kepala Admin** menggantikan lewat menu Pengaturan.

**Lampu di pojok kanan atas:**

| Lampu | Arti | Yang harus dilakukan |
|---|---|---|
| 🟢 Tersambung | Internet dan database normal | lanjut kerja |
| 🟡 Sinyal lemah | Internet ada tapi database lambat | tunggu sebentar, biasanya pulih sendiri |
| 🔴 Luring | Internet mati | **tetap boleh memindai** — otomatis terkirim saat internet kembali |

---

## 🗂️ ADMIN HARIAN

Tugasmu satu: memasukkan pesanan hari ini supaya Gudang bisa memindai.

**1. Unggah label**
Cetak label seperti biasa dari Shopee, lalu simpan juga PDF-nya. Tarik file PDF itu ke kotak di halaman **Unggah Label**. Satu file boleh berisi ratusan label — tidak perlu satu per satu.

**2. Periksa hasil bacaan**
Sistem menampilkan berapa pesanan terbaca, berapa baris barang, dan berapa yang **tanpa SKU**. Toko biasanya terdeteksi otomatis dari nama Pengirim di label — kalau salah, ganti sendiri di kotak Toko.

**3. Tekan “Kirim & Periksa”**
Muncul daftar semua barang. Kolom **Cocok** memberi tahu apakah sistem menemukan barangnya:

- hijau = ketemu, aman
- merah = tidak ketemu. Gudang akan **ditolak** saat memindai pesanan itu. Laporkan ke Kepala Admin agar SKU-nya ditambahkan.

**4. Kalau jumlah salah baca — isi +FIX**
Contoh: label sebenarnya 4 pcs, tapi terbaca 1. Isi kolom **+FIX** dengan **3** (selisihnya, bukan totalnya). Kolom “Jadi” langsung menunjukkan hasilnya. Boleh minus kalau kelebihan.

**5. Tekan “Konfirmasi & Lanjut”**
Baru setelah ini Gudang bisa memindai. Kalau belum ditekan, scanner akan menolak.

> Tab **Stok Saat Ini** hanya untuk dilihat. Menambah stok bukan tugas Admin Harian.

---

## 📷 GUDANG

**Memindai**

Buka tab **Pindai Label**. Kursor otomatis siap — tidak perlu klik apa pun. Tembak barcode di label yang sudah tercetak. Barcode garis (No. Pesanan) atau QR (No. Resi), dua-duanya bisa.

| Bunyi | Arti |
|---|---|
| 🔊 satu nada tinggi | berhasil, stok sudah dipotong |
| 🔊 dua nada pendek | label ini **sudah pernah** dipindai — stok TIDAK dipotong dua kali |
| 🔊 nada rendah panjang | ada masalah, baca tulisan di layar |

Kotak pesanan yang berhasil menyala hijau lalu hilang dari daftar.

**Kalau tulisannya merah:**

| Tulisan | Artinya |
|---|---|
| Pesanan tidak ada | Admin belum mengunggah label ini |
| Belum dikonfirmasi Admin | Admin sudah unggah tapi belum tekan Konfirmasi |
| SKU belum cocok | Barangnya belum terdaftar. **Tidak ada stok yang dipotong sama sekali** — bukan sebagian. Lapor ke Admin |
| Sudah pernah dipindai | Aman. Ini pengaman bekerja, bukan error |

**Salah pindai?** Tekan **Batalkan pemindaian ini** di kartu hijau. Stok kembali seperti semula.

**Tab Barang Keluar** — semua SKU dari pesanan yang sudah kamu pindai, digabung jadi satu daftar dengan jumlah `x4`. Pakai ini untuk mengambil barang dari rak sekali jalan. Ketuk kotak untuk melihat pesanan mana saja yang butuh barang itu. Angka **merah** artinya ada koreksi dari Admin.

**Tab Stok Masuk** — barang datang dari supplier. Cari SKU, tekan `+1`, `+10`, `+50`, atau `+ Lain`. Membuat SKU baru hanya bisa Kepala Admin.

**Internet mati?** Lanjut saja memindai. Muncul kartu oranye “Disimpan (luring)” dan tulisan kecil di pojok kanan bawah berapa yang menunggu. Begitu internet kembali, semua terkirim otomatis.

---

## 🔑 KEPALA ADMIN

**Ringkasan** — angka hari ini, dan peringatan merah kalau ada yang perlu ditangani.

**Jalankan pemeriksaan** — ini **bukan** cek internet (itu lampu di pojok). Ini mencari masalah data:

- baris pesanan yang akan ditolak scanner → perbaiki sebelum jam packing
- SKU kembar (satu SKU dipakai dua variasi) → perbaiki di Shopee
- stok minus → berarti hitungan sudah salah sebelumnya, perlu opname
- stok di atas 1.000 → biasanya angka bawaan Shopee, bukan hitungan asli

**Stok** — bisa tampilan **Kotak** atau **Daftar**. Ketuk barang → `+1` `+10` `+50` atau isi sendiri. Perubahan menumpuk dulu, baru tekan **Simpan Semua Perubahan**. Di jendela yang sama ada **opname** (setel ke hasil hitung fisik) dan **titik pesan ulang** (batas peringatan menipis).

**Harga & Nilai** — semua harga sengaja kosong di awal. Ketik lalu pindah kolom, tersimpan sendiri. Total nilai stok terhitung otomatis. **Halaman Admin Harian dan Gudang tidak bisa melihat tab ini sama sekali.**

**Riwayat** — semua pergerakan stok: apa, berapa, pesanan mana, siapa, kapan. Bisa diekspor ke Excel. Otomatis dibersihkan setelah 1 tahun.

**Kiriman Admin** — berapa banyak yang harus dikoreksi tangan tiap hari, plus daftar rinci apa yang terbaca dari PDF dan berapa yang ditambahkan. **Kalau angka koreksi lewat 25%, muncul peringatan merah** — hampir selalu karena SKU belum dipasang di listing Shopee, bukan admin yang ceroboh.

**Produk & Foto** — tambah SKU baru, dan alat penyiap foto (otomatis dipotong kotak 400×400, ukuran kecil).

**Unduh Foto Shopee** — pilih file ekspor `mass_update_media_info…xlsx`, lalu tekan **Unduh gambar utama (ZIP)**. Hanya kolom **Foto Sampul** yang diambil; foto variasi dan foto produk tambahan sengaja dilewati. ZIP memakai nama SKU Induk agar mudah dicari.

**Pengaturan** — ganti PIN siapa saja, atur nama toko dan ejaan “Pengirim” di label, impor ulang master produk dari Shopee.

---

## Aturan yang tidak bisa dilanggar siapa pun

1. Satu label hanya bisa memotong stok **satu kali**. Dipindai sepuluh kali pun tetap sekali.
2. Kalau ada satu barang yang tidak dikenali, **seluruh pesanan ditolak**. Tidak pernah terpotong setengah-setengah.
3. Setiap perubahan stok tercatat: apa, berapa, karena pesanan mana, oleh siapa, jam berapa.
4. Gudang tidak bisa melihat harga. Admin Harian tidak bisa mengubah stok. Membuat SKU baru hanya Kepala Admin.

---

## Kalau ada masalah

| Gejala | Coba ini |
|---|---|
| Halaman kosong / aneh | tarik layar ke bawah untuk muat ulang |
| Lampu merah terus padahal wifi ada | tunggu 1 menit, lampu memeriksa sendiri tiap menit |
| Scanner tidak membaca | pastikan kursor ada di kotak besar; ketuk sekali di area kosong |
| Scanner mengetik tapi tidak jalan | scanner harus dipasang mengirim **Enter** setelah membaca |
| PIN tidak diterima | minta Kepala Admin ganti PIN |


---

# Tambahan v3

## 📷 GUDANG — kalau ada SKU yang tidak dikenal

Barang tetap harus dikirim, jadi sekarang ada jalan keluarnya.

Waktu layar merah bertuliskan **“SKU belum cocok”**, muncul tombol **🚚 Lanjut Kirim**.

1. Tekan tombol itu.
2. Isi alasannya (mis. “barang sudah terlanjur dikemas”).
3. Barang yang **sudah dikenali** tetap dipotong stoknya. Yang belum dikenali dicatat sebagai utang data.
4. Kepala Admin langsung dapat pemberitahuan merah — kamu tidak perlu lapor manual.

Kamu tidak sedang “curang”. Kamu sedang mencatat kenyataan supaya bisa dibetulkan nanti.

## 📷 GUDANG — menambah barang ke sebuah pesanan

Kalau ada barang yang harus ikut dikirim tapi tidak tercetak di label:

1. Di kartu hijau hasil pemindaian, tekan **➕ Tambah barang ke pesanan ini**.
2. Ketik SKU atau nama produknya, pilih jumlah (`+1`, `+2`, atau isi sendiri).
3. Isi catatan singkat kenapa ditambahkan.

Stok langsung dipotong **satu kali saja**, dan Kepala Admin langsung diberi tahu SKU apa, berapa, dan catatanmu. Di Riwayat tercatat sebagai **keluar_tambahan**.

## 📷 GUDANG — Retur Masuk

Tab **Retur Masuk** hanya menampilkan retur yang **sudah disetujui Kepala Admin**.

Kalau barangnya benar-benar sudah ada di tanganmu, tekan **✓ Barang sudah diterima**. Stok baru bertambah di detik itu. Jangan menekan tombol ini sebelum barangnya benar-benar dicek.

## 📷 GUDANG — Sesi Opname

Tidak perlu stiker, tidak perlu scan. Cukup hitung dan ketik.

1. Tab **Opname** → beri judul (mis. “Opname rak A — Agustus”) → **Mulai sesi baru**.
2. Cari SKU, isi kolom **Hitungan** dengan jumlah asli di rak. Kolom **Selisih** langsung terlihat: hijau = pas, merah = beda.
3. Boleh berhenti dan lanjut lagi nanti — sesi tersimpan.
4. Kalau sudah, tekan **Ajukan ke Kepala Admin**. Sesi terkunci.
5. **Stok belum berubah.** Baru berubah setelah Kepala Admin menyetujui.

Kosongkan kolom Hitungan untuk SKU yang tidak ikut dihitung hari itu.

## 🗂️ ADMIN HARIAN — Retur COD

Tab **Retur COD**. Ini untuk paket COD yang kembali karena ditolak pembeli.

1. Pilih toko, ketik **No. Pesanan** (wajib), No. Resi (boleh kosong), dan alasannya.
2. Tambahkan baris untuk tiap barang: ketik SKU (atau nama produknya kalau SKU tidak tahu), variasi, jumlah.
3. Tekan **Ajukan ke Kepala Admin**.

**Pengajuanmu tidak menambah stok.** Alurnya: kamu ajukan → Kepala Admin setujui → Gudang konfirmasi barangnya sudah masuk → baru stok naik.

Kalau muncul tulisan kuning “SKU belum cocok”, artinya SKU itu belum ada di master. Kepala Admin tidak bisa menyetujui sebelum SKU-nya ditambahkan.

## 🔑 KEPALA ADMIN — tab baru

**Notifikasi** — semua kejadian tak biasa berkumpul di sini: SKU tidak dikenal, pesanan yang dihijaukan paksa (lengkap dengan alasan, petugas, dan perangkatnya), barang yang ditambahkan Gudang, retur, opname, dan pergantian PIN. Tekan **Tandai selesai** kalau sudah ditangani, boleh sambil menulis catatan.

Di bawahnya, tabel **Pesanan bermasalah** — daftar semua pesanan yang dihijaukan paksa tanpa pemindaian penuh.

**Persetujuan** — retur menunggu tanda tanganmu, dan sesi opname dari Gudang. Untuk opname, tekan **Lihat selisih** dulu; yang ditampilkan hanya baris yang berbeda.

**Kiriman LCL** — buat kode kiriman (mis. `LCL-2026-08-A`), isi daftar barang yang **diharapkan** datang. Setiap kali Gudang menerima barang sambil memilih kiriman itu, batangnya jalan sendiri: `60 / 150 unit (40%)`.

**Pengaturan → Perangkat** — daftar semua HP/tablet/komputer yang pernah dipakai memindai. Beri nama supaya mudah dikenali. Kalau **Kunci perangkat** dinyalakan, hanya perangkat yang kamu centang yang boleh memindai — perangkat asing ditolak.

## Label TikTok / Tokopedia

Sudah bisa dibaca otomatis. Admin Harian tidak perlu melakukan apa pun berbeda — tarik PDF-nya seperti biasa.

Satu hal yang perlu diketahui: di label TikTok, kolom bertuliskan **“SKU”** sebenarnya berisi **variasi** (Hitam, Default). SKU yang asli ada di kolom **“Seller SKU”**, dan di toko kalian kolom itu masih kosong. Sistem menutupinya dengan mencocokkan nama produk, tapi selama Seller SKU belum diisi di TikTok Seller Center, akan selalu ada yang lolos.


---

# Tambahan v4 — kalau SKU tidak dikenal

## 🔑 KEPALA ADMIN — Petakan ke SKU

Tab **Notifikasi** sekarang dibuka dengan kotak merah **"SKU belum cocok — petakan sekali, beres selamanya"**.

Ini muncul kalau sistem tidak yakin barang di label itu SKU yang mana. Penyebab paling sering: label TikTok mengosongkan kolom **Seller SKU**, dan nama produk yang dicetak lebih pendek daripada nama di katalog.

1. Tekan **🔗 Petakan ke SKU**.
2. Sistem mengusulkan beberapa SKU, yang paling atas tebakan terbaiknya. **Periksa dulu** — jangan asal pilih, padanan ini dipakai untuk semua label berikutnya.
3. Kalau tidak ada yang cocok, ketik sendiri di kotak pencarian bawah.
4. Tekan **Pilih** lalu konfirmasi.

Yang langsung terjadi:

- Semua pesanan yang macet karena barang itu **langsung beres** — Gudang bisa memindai lagi.
- Notifikasi terkait ikut ditutup sendiri.
- Label berikutnya dengan nama sama **cocok otomatis**, selamanya.

Kamu **tidak perlu** mengubah apa pun di TikTok atau Shopee.

Daftar padanan yang pernah disimpan ada di **Pengaturan → Buku terjemahan nama produk**. Boleh dihapus kalau salah petakan. Isinya tidak pernah dihapus otomatis.

## 🗂️ ADMIN HARIAN — kalau toko tidak terdeteksi

Label TikTok kadang mencetak **NickName** toko, kadang cuma nama orang di **Pengirim**. Sistem mencoba dua-duanya, dan menuliskan nama mana yang dipakai, mis. *Toko (terdeteksi dari "EVANO DANY")*.

Kalau tertulis **"tidak terdeteksi — pilih sendiri"**, pilih tokonya manual, lalu minta Kepala Admin memasukkan nama yang tertera di label ke daftar toko. Setelah itu otomatis.

---

## Tambahan v7 — Stok SKU Utama, edit nama, dan persetujuan

### Gudang

Di tab **Stok Masuk**, yang terlihat hanya **SKU Utama / SKU Induk**. Ketuk satu baris untuk melihat semua tipe SKU dan stoknya. Dari sana:

1. Tekan **Edit…** pada tipe yang benar, isi jumlah, lalu **Ajukan ke Kepala Admin**.
2. Pastikan muncul pesan bahwa pengajuan sudah tersimpan di Supabase dan label **+… menunggu**. Angka stok aktual belum berubah.
3. Di layar yang sama, ubah nama produk, nama tipe, atau kode SKU bila perlu, lalu ajukan. Master SKU juga belum berubah sebelum disetujui.
4. Jika internet putus, pengajuan bertanda menunggu koneksi. Pengajuan belum dianggap masuk ke Supabase sampai koneksi kembali.

### Kepala Admin

Tab **Stok** juga hanya menampilkan SKU Induk. Ketuk untuk membuka tipe SKU dan totalnya, lalu tekan **Edit…**. Kepala Admin dapat memasukkan jumlah ke daftar perubahan dan menyimpannya bersama melalui tombol **Simpan Semua Perubahan**, atau mengubah nama SKU langsung.

Di tab **Persetujuan**, periksa dua bagian dari Gudang:

- **Stok masuk menunggu persetujuan** — periksa SKU, tipe, jumlah, stok saat diajukan, stok sekarang, dan catatan. Pilih **Setujui** agar stok bertambah, atau **Tolak** agar stok tetap.
- **Usulan perubahan nama SKU** — bandingkan data sebelum dan sesudah, lalu pilih **Setujui** atau **Tolak**.

### Foto

Satu foto dipakai semua tipe di bawah SKU Induk. Nama file normalnya adalah `<SKU-INDUK>.jpg` di folder `img/`; tidak perlu lagi mengunggah foto untuk setiap variasi.
