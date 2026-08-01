# Sistem Gudang

Aplikasi gudang berbasis halaman statis dengan tiga peran:

- **Admin Harian**: unggah label, lihat stok, dan ajukan retur COD.
- **Gudang**: pindai barang keluar, ajukan stok masuk, terima retur, opname, dan catat peminjaman.
- **Kepala Admin**: persetujuan, koreksi stok, harga/nilai stok, master SKU, notifikasi, dan audit keputusan.

## Hosting

Situs dirancang untuk Cloudflare Pages sebagai proyek statis tanpa proses build.

- Framework: `None`
- Build command: kosong
- Output directory: `/`
- Nama proyek: `ops-7k2m`

Semua alamat aset memakai jalur relatif. `_headers`, `_redirects`, dan `robots.txt` ikut diterbitkan untuk keamanan dasar dan mencegah pengindeksan.

GitHub Pages lama dipertahankan hanya selama proses perpindahan. Setelah alamat Cloudflare terbukti berfungsi, nonaktifkan GitHub Pages dan ubah repository menjadi private.

## Database

Skema database tidak boleh berada di repository atau hosting publik. Arsip lokal gabungan tersedia di:

`db/skema-lengkap.sql.txt`

Folder `db/` serta patch database operasional diabaikan oleh Git. Patch terbaru sudah dijalankan langsung melalui editor database dan tidak boleh di-commit.

Aturan penting:

- Semua gerakan stok hanya melalui fungsi server dan dicatat di buku besar stok.
- Stok masuk dari Gudang menunggu persetujuan Kepala Admin.
- Keputusan Kepala Admin dicatat di `riwayat_keputusan`.
- Notifikasi bersifat append-only; notifikasi lama hanya ditutup, bukan dihapus.
- Riwayat operasional lebih dari satu tahun dibersihkan otomatis setiap bulan.
- Harga hanya dapat dibaca dan diubah melalui fungsi khusus Kepala Admin.
- Operasi stok mengunci baris pesanan/variasi untuk mencegah potongan ganda saat dua perangkat bekerja bersamaan.

## Konfigurasi

`config.js` hanya boleh memuat URL layanan data dan publishable/anon key yang memang ditujukan untuk aplikasi browser. Jangan pernah menyimpan PIN, service-role key, secret key, atau kredensial pribadi di repository.

## Foto produk

Satu foto dipakai per SKU Induk. Letakkan file di folder `img/` dan gunakan nama yang sama dengan SKU Induk, misalnya:

`HUB-XPRO-32H.jpg`

Variasi di bawah SKU Induk akan memakai foto yang sama. Foto bersifat opsional.

## Pengujian minimum sebelum rilis

1. Masuk sebagai Admin Harian, Gudang, dan Kepala Admin.
2. Pastikan Admin/Gudang tidak dapat membaca harga.
3. Uji unggah label dan pemindaian pesanan.
4. Uji penolakan dan penerimaan sebagian.
5. Uji stok masuk sampai persetujuan.
6. Uji retur: ditemukan, pesanan lama, dan COD tidak ditemukan.
7. Uji opname normal dan angka janggal.
8. Uji peminjaman serta pengembalian tanpa perubahan stok.
9. Pastikan setiap persetujuan/penolakan muncul di Riwayat Keputusan.
10. Pastikan tidak ada file `.sql` yang dapat diakses dari alamat situs.

`assets/parser.js` adalah parser label yang sudah distabilkan dan tidak boleh diubah tanpa pengujian ulang terhadap seluruh contoh PDF.
