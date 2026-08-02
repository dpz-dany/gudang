/* ============================================================
   Inti bersama: koneksi, PIN, jam, LED, antrean offline, alat bantu
   ============================================================ */

const $  = id => document.getElementById(id);
const $$ = sel => [...document.querySelectorAll(sel)];
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const nf  = n => Number(n || 0).toLocaleString('id-ID');
const rp  = n => (n == null || n === '') ? '—' : 'Rp ' + Number(n).toLocaleString('id-ID');

const ATURAN_ERROR = Object.freeze({
  1:{judul:'Label tidak terbaca',sebab:'PDF rusak atau format asing',tindakan:'Unggah ulang PDF yang benar atau masukkan pesanan melalui alur yang tersedia.'},
  2:{judul:'Toko tidak dikenal di label',sebab:'Nama pengirim belum terdaftar',tindakan:'Admin memilih toko secara manual lalu Kepala menambahkan nama pengirim.'},
  3:{judul:'Toko tidak ditemukan',sebab:'Kiriman bukan milik toko yang terdaftar',tindakan:'Kepala menolak kiriman dengan alasan yang jelas.'},
  10:{judul:'SKU kosong di label',sebab:'Label tidak mencetak Seller SKU',tindakan:'Kepala memetakan nama produk ke SKU yang benar.'},
  11:{judul:'SKU tidak ada di master',sebab:'SKU label belum terdaftar',tindakan:'Kepala menambah atau memetakan SKU.'},
  12:{judul:'SKU ganda',sebab:'Satu SKU dipakai dua variasi',tindakan:'Kepala memperbaiki salah satu kode SKU.'},
  20:{judul:'Jumlah salah baca',sebab:'Hasil pembacaan PDF perlu dikoreksi',tindakan:'Admin mengisi +FIX sebelum konfirmasi.'},
  21:{judul:'Pesanan asing',sebab:'Pesanan bukan barang kita',tindakan:'Gudang menolak pesanan dan mencatat alasannya.'},
  22:{judul:'Pesanan dikirim paksa',sebab:'Sebagian SKU belum dapat dipotong',tindakan:'Kepala memeriksa barang yang belum terpotong.'},
  23:{judul:'Pesanan diterima sebagian',sebab:'Gudang hanya mengirim barang yang dipilih',tindakan:'Kepala memeriksa barang yang tidak dikirim.'},
  30:{judul:'Retur pesanan lama',sebab:'Dikirim sebelum sistem dipakai (wajar)',tindakan:'Kepala memeriksa SKU lalu menyetujui bila fisiknya benar.'},
  31:{judul:'Retur ditolak Kepala',sebab:'Pengajuan retur tidak disetujui',tindakan:'Baca alasan penolakan dan perbaiki bila perlu.'},
  32:{judul:'Retur melebihi pengiriman',sebab:'Jumlah retur lebih besar dari jumlah yang pernah dikirim',tindakan:'Admin mengurangi jumlah sesuai riwayat pengiriman.'},
  33:{judul:'Retur COD tidak ditemukan',sebab:'No. Pesanan seharusnya sudah tercatat',tindakan:'Kepala memeriksa nomor pesanan dan barang fisik.'},
  40:{judul:'Opname janggal',sebab:'Selisih di luar batas wajar',tindakan:'Kepala wajib meninjau dan menandai sudah diperiksa.'},
  41:{judul:'Opname ditolak Kepala',sebab:'Hasil hitungan belum dapat disetujui',tindakan:'Gudang membuat hitungan baru sesuai alasan penolakan.'},
  50:{judul:'Stok minus',sebab:'Stok menjadi minus setelah pemotongan',tindakan:'Lakukan opname dan telusuri gerakan stok.'},
  51:{judul:'Pemindaian ganda ditolak',sebab:'Pesanan sudah pernah dipindai',tindakan:'Jangan potong stok lagi; periksa riwayat bila perlu.'},
  60:{judul:'Barang ditambahkan Gudang',sebab:'Barang tidak tercantum pada label',tindakan:'Kepala memeriksa alasan dan gerakan stok.'},
  70:{judul:'Peminjaman melewati batas',sebab:'Barang dipinjam lebih dari 14 hari',tindakan:'Minta pengembalian atau perbarui tindak lanjut.'}
});
function lencanaError(kode) {
  const a = ATURAN_ERROR[Number(kode)];
  if (!a) return '';
  const warna = Number(kode) === 30 ? '' : Number(kode) === 33 ? 'bad' : 'warn';
  return `<span class="tag ${warna}" title="${esc(a.sebab)}">${Number(kode)} · ${esc(a.judul)}</span>`;
}

const simpan = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : v; }
              catch (e) { return (this._m || {})[k] ?? d; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) { (this._m = this._m || {})[k] = v; } },
  getJSON(k, d) { try { return JSON.parse(this.get(k, '')) ?? d; } catch (e) { return d; } },
  setJSON(k, v) { this.set(k, JSON.stringify(v)); }
};

let _tt;
function pesan(t) {
  const el = $('toast'); if (!el) return alert(t);
  el.textContent = t; el.classList.add('show');
  clearTimeout(_tt); _tt = setTimeout(() => el.classList.remove('show'), 3000);
}

let _ac;
function bunyi(jenis) {
  try {
    _ac = _ac || new (window.AudioContext || window.webkitAudioContext)();
    const pola = jenis === 'ok'   ? [[900, .09]]
              : jenis === 'ulang' ? [[620, .08], [620, .08]]
              :                     [[250, .16], [190, .24]];
    let t = _ac.currentTime;
    for (const [f, d] of pola) {
      const o = _ac.createOscillator(), g = _ac.createGain();
      o.type = 'square'; o.frequency.value = f;
      g.gain.setValueAtTime(.0001, t);
      g.gain.exponentialRampToValueAtTime(.16, t + .012);
      g.gain.exponentialRampToValueAtTime(.0001, t + d);
      o.connect(g); g.connect(_ac.destination); o.start(t); o.stop(t + d + .02);
      t += d + .045;
    }
  } catch (e) {}
}

/* ---------------- jam ---------------- */
const HARI  = ['Minggu','Senin','Selasa','Rabu','Kamis','Jumat','Sabtu'];
const BULAN = ['Januari','Februari','Maret','April','Mei','Juni','Juli',
               'Agustus','September','Oktober','November','Desember'];
function mulaiJam() {
  const el = $('jam'); if (!el) return;
  const tik = () => {
    const d = new Date();
    el.innerHTML = '<b>' + String(d.getHours()).padStart(2,'0') + ':' +
      String(d.getMinutes()).padStart(2,'0') + ':' + String(d.getSeconds()).padStart(2,'0') + '</b>' +
      HARI[d.getDay()] + ', ' + d.getDate() + ' ' + BULAN[d.getMonth()] + ' ' + d.getFullYear();
  };
  tik(); setInterval(tik, 1000);
}
const hariIni = () => new Date().toISOString().slice(0, 10);

/* ---------------- koneksi ---------------- */
let sb = null, sesi = null, peranSaya = null;

function buatKlien() {
  if (!window.CFG || CFG.SUPABASE_URL.includes('GANTI-INI')) return null;
  try {
    return window.supabase.createClient(CFG.SUPABASE_URL, CFG.SUPABASE_ANON,
      { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'gudang-auth' } });
  } catch (e) { return null; }
}

/* LED koneksi.
   Tidak ada polling agresif: kita pakai event online/offline milik browser,
   ditambah SATU ping ringan tiap 60 detik (head-only, tanpa data). */
let ledNyala = true;
function setLed(status, teks) {
  const el = $('led'); if (!el) return;
  el.className = 'led' + (status === 'ok' ? '' : status === 'wait' ? ' wait' : ' off');
  el.innerHTML = '<i></i>' + teks;
  ledNyala = status === 'ok';
}
async function cekKoneksi() {
  if (!navigator.onLine) { setLed('off', 'Luring'); return false; }
  if (!sb) { setLed('off', 'Belum diatur'); return false; }
  try {
    const { error } = await sb.from('shops').select('shop_id', { head: true, count: 'exact' }).limit(1);
    if (error) throw error;
    setLed('ok', 'Tersambung'); return true;
  } catch (e) { setLed('wait', 'Sinyal lemah'); return false; }
}
function mulaiLed() {
  addEventListener('online',  () => { cekKoneksi().then(ok => ok && kirimAntrean()); });
  addEventListener('offline', () => setLed('off', 'Luring'));
  cekKoneksi();
  setInterval(async () => { const ok = await cekKoneksi(); if (ok) kirimAntrean(); }, 60000);
}

/* ---------------- masuk dengan PIN ---------------- */
const emailPeran = p => p + '@' + CFG.DOMAIN_AKUN;

async function masukPIN(peran, pin) {
  if (!sb) return { ok: false, pesan: 'Sistem belum diatur (config.js).' };
  const { error } = await sb.auth.signInWithPassword({ email: emailPeran(peran), password: pin });
  if (error) return { ok: false, pesan: 'PIN salah.' };
  const r = await ambilPeran();
  if (r !== peran) { await sb.auth.signOut(); return { ok: false, pesan: 'Akun tidak cocok dengan peran.' }; }
  return { ok: true };
}
async function ambilPeran() {
  const { data } = await sb.rpc('my_role');
  peranSaya = data || null; return peranSaya;
}
async function autoArahLoginAktif() {
  if (!sb) return false;
  try {
    const { data, error } = await sb.rpc('auto_arah_login_aktif');
    return !error && data === true;
  } catch (e) { return false; }
}
async function keluar() { if (sb) await sb.auth.signOut(); location.href = './'; }

/* Penjaga halaman: setiap halaman menyebut peran yang boleh membukanya.
   Ini hanya lapisan tampilan — penegakan sebenarnya ada di RLS Supabase,
   jadi membuka DevTools tidak membuka data peran lain. */
async function jagaHalaman(peranWajib) {
  sb = buatKlien();
  mulaiJam();
  if (!sb) { setLed('off', 'Belum diatur'); return false; }
  mulaiLed();
  const { data } = await sb.auth.getSession();
  sesi = data.session;
  if (!sesi) { location.href = './?dari=' + encodeURIComponent(location.pathname.split('/').pop()); return false; }
  const r = await ambilPeran();
  if (r !== peranWajib && r !== 'kepala') { location.href = './'; return false; }
  const w = $('siapa'); if (w) w.textContent = ({admin:'Admin Harian', gudang:'Gudang', kepala:'Kepala Admin'})[r] || r;
  const nm = $('namaPetugas');
  if (nm) {
    if (nm.tagName === 'SELECT') await muatPilihanPetugas(nm);
    else nm.value = simpan.get('gudang.petugas', '');
    nm.onchange = nm.oninput = e => simpan.set('gudang.petugas', e.target.value);
  }
  return true;
}
const petugas = () => (($('namaPetugas') || {}).value || '').trim() || null;

async function muatPilihanPetugas(el = $('namaPetugas')) {
  if (!el || !sb) return;
  const dipilih = simpan.get('gudang.petugas', '');
  const { data, error } = await sb.from('petugas_gudang').select('nama').eq('aktif', true).order('nama');
  const rows = error ? [] : (data || []);
  el.innerHTML = '<option value="">— pilih petugas —</option>' +
    rows.map(x => `<option value="${esc(x.nama)}">${esc(x.nama)}</option>`).join('');
  if (rows.some(x => x.nama === dipilih)) el.value = dipilih;
  else if (rows.some(x => x.nama === 'Mandor')) {
    el.value = 'Mandor';
    simpan.set('gudang.petugas', 'Mandor');
  }
}

/* Dialog operasional: tombol tutup selalu tersedia, tombol bawah tetap terlihat,
   Escape tetap native, dan ketukan pada latar menutup dialog. */
function siapkanDialog(dlg) {
  if (!dlg || dlg.dataset.siap === '1') return;
  dlg.dataset.siap = '1';
  const pasangTutup = () => {
    const isi = dlg.querySelector('.dlg');
    if (isi && !isi.querySelector('.dlg-x')) {
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'dlg-x'; b.setAttribute('aria-label','Tutup');
      b.textContent = '×'; b.onclick = () => dlg.close(); isi.prepend(b);
    }
  };
  new MutationObserver(pasangTutup).observe(dlg, { childList:true, subtree:true });
  dlg.addEventListener('click', e => { if (e.target === dlg) dlg.close(); });
  pasangTutup();
}
addEventListener('DOMContentLoaded', () => $$('dialog').forEach(siapkanDialog));

/* ---------------- antrean luring ---------------- */
const ANTREAN = 'gudang.antrean';
const antrean = () => simpan.getJSON(ANTREAN, []);
function tulisAntrean(a) { simpan.setJSON(ANTREAN, a); tampilAntrean(); }
function tampilAntrean() {
  const n = antrean().length, el = $('antrean');
  if (!el) return;
  el.classList.toggle('hide', n === 0);
  el.textContent = '⏳ ' + n + ' pemindaian menunggu kirim';
}
/* ID perangkat: tetap selama browser tidak dibersihkan. Dipakai untuk
   melacak siapa memindai dari mana, dan (kalau "kunci perangkat" dinyalakan
   Kepala Admin) untuk menolak perangkat yang belum terdaftar. */
function idPerangkat() {
  let d = simpan.get('gudang.dev', '');
  if (!d) { d = 'D-' + Math.random().toString(36).slice(2, 8).toUpperCase(); simpan.set('gudang.dev', d); }
  return d;
}
function idKlien() {
  return idPerangkat() + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
}

/* Panggil RPC; kalau gagal karena jaringan, simpan ke antrean. */
async function rpcAman(fn, args, bolehAntre) {
  if (!navigator.onLine && bolehAntre) { const a = antrean(); a.push({ fn, args }); tulisAntrean(a);
    return { data: { ok: true, antre: true }, error: null }; }
  try {
    const r = await sb.rpc(fn, args);
    if (r.error && bolehAntre && /fetch|network|Failed/i.test(r.error.message || '')) throw r.error;
    return r;
  } catch (e) {
    if (!bolehAntre) return { data: null, error: e };
    const a = antrean(); a.push({ fn, args }); tulisAntrean(a);
    return { data: { ok: true, antre: true }, error: null };
  }
}

let sedangKirim = false;
async function kirimAntrean() {
  if (sedangKirim || !sb || !navigator.onLine) return;
  const a = antrean(); if (!a.length) return;
  sedangKirim = true;
  const sisa = [], masalah = [];
  for (const t of a) {
    try {
      const { data, error } = await sb.rpc(t.fn, t.args);
      if (error) { sisa.push(t); continue; }
      if (data && data.ok === false) masalah.push({ t, data });
    } catch (e) { sisa.push(t); }
  }
  tulisAntrean(sisa);
  sedangKirim = false;
  if (masalah.length) {
    const rin = simpan.getJSON('gudang.masalah', []);
    simpan.setJSON('gudang.masalah', rin.concat(masalah.map(m => ({
      waktu: new Date().toISOString(), scan: m.t.args.p_scan || m.t.args.p_variation_id, kode: m.data.code
    }))).slice(-200));
    pesan('⚠️ ' + masalah.length + ' pemindaian tertunda ditolak saat sinkron. Cek dengan Kepala Admin.');
  } else if (a.length) pesan('✅ ' + a.length + ' pemindaian tertunda berhasil dikirim.');
}

/* ---------------- foto produk ---------------- */
const NOFOTO = 'data:image/svg+xml;utf8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120"><rect width="120" height="120" fill="%23f1f4f8"/></svg>');
function fotoURL(u, skuInduk) {
  // Foto dimiliki SKU Induk. Nama standar <SKU-INDUK>.jpg, sementara
  // file khusus (misalnya WebP baru) disimpan di products.image_url.
  const berkas = u || (skuInduk ? String(skuInduk).trim() + '.jpg' : '');
  if (!berkas) return null;
  return /^https?:/.test(berkas) ? berkas : (CFG.FOLDER_FOTO + berkas.replace(/^\/+/, ''));
}

/* Sebagian foto lama memiliki bingkai biru EVANO DANY yang sudah menyatu
   dengan JPG. Deteksi hanya dilakukan pada empat sudut gambar. Foto asli
   tidak diubah; CSS menyembunyikan pita atas/bawah ketika pola cocok. */
const statusBingkaiFoto = new Map();
function fotoTanpaBingkai(img) {
  const sumber = img.currentSrc || img.src;
  const tersimpan = statusBingkaiFoto.get(sumber);
  if (tersimpan != null) {
    img.classList.toggle('foto-bingkai-lama', tersimpan);
    img.parentElement?.classList.toggle('wadah-foto-tanpa-bingkai', tersimpan);
    return;
  }
  try {
    const c = document.createElement('canvas'); c.width = 4; c.height = 1;
    const x = c.getContext('2d', { willReadFrequently:true });
    const w = img.naturalWidth, h = img.naturalHeight;
    if (!w || !h) return;
    x.drawImage(img, 0, 0, 1, 1, 0, 0, 1, 1);
    x.drawImage(img, w - 1, 0, 1, 1, 1, 0, 1, 1);
    x.drawImage(img, 0, h - 1, 1, 1, 2, 0, 1, 1);
    x.drawImage(img, w - 1, h - 1, 1, 1, 3, 0, 1, 1);
    const p = x.getImageData(0, 0, 4, 1).data;
    let cocok = 0;
    for (let i = 0; i < 16; i += 4) {
      const r = p[i], g = p[i + 1], b = p[i + 2];
      if (r < 18 && g >= 18 && g <= 55 && b >= 60 && b <= 105 && b > g + 28) cocok++;
    }
    const adaBingkai = cocok >= 3;
    statusBingkaiFoto.set(sumber, adaBingkai);
    img.classList.toggle('foto-bingkai-lama', adaBingkai);
    img.parentElement?.classList.toggle('wadah-foto-tanpa-bingkai', adaBingkai);
  } catch (_) {
    // URL foto eksternal mungkin tidak dapat diperiksa oleh canvas.
    statusBingkaiFoto.set(sumber, false);
  }
}
function thumb(u, skuInduk) {
  const s = fotoURL(u, skuInduk);
  return s ? `<div class="thumb"><img src="${esc(s)}" alt="Foto produk" loading="lazy"
    onload="fotoTanpaBingkai(this)" onerror="this.remove();this.parentElement.textContent='📦'"></div>`
           : `<div class="thumb">📦</div>`;
}

/* Stok tetap tercatat per variasi. Ini hanya pengelompokan tampilan agar
   ratusan variasi tidak memenuhi layar operasional. */
function kelompokStokInduk(rows) {
  const map = new Map();
  (rows || []).forEach(r => {
    const induk = String(r.parent_sku || r.sku || '').trim();
    if (!induk) return;
    const id = String(r.shop_id || '') + '::' + induk;
    let g = map.get(id);
    if (!g) {
      g = { id, shop_id:r.shop_id, sku_induk:induk,
        product_name:r.product_name || '', image_url:r.image_url || null,
        stock_on_hand:0, stok_dipinjam:0, jumlah_tipe:0, perlu_restock:false,
        ada_stok_kosong:false, ada_stok_minus:false, variasi:[] };
      map.set(id, g);
    }
    if (!g.product_name && r.product_name) g.product_name = r.product_name;
    if (!g.image_url && r.image_url) g.image_url = r.image_url;
    g.stock_on_hand += Number(r.stock_on_hand || 0);
    g.stok_dipinjam += Number(r.stok_dipinjam || 0);
    g.jumlah_tipe += 1;
    g.perlu_restock ||= !!r.perlu_restock;
    g.ada_stok_kosong ||= Number(r.stock_on_hand || 0) === 0;
    g.ada_stok_minus ||= Number(r.stock_on_hand || 0) < 0;
    g.variasi.push(r);
  });
  return [...map.values()].sort((a,b) => a.sku_induk.localeCompare(b.sku_induk));
}

/* ---------------- daftar tab ---------------- */
function pasangTab(daftar, awal) {
  $$('#tabs button').forEach(b => b.onclick = () => bukaTab(b.dataset.tab));
  window.bukaTab = name => {
    $$('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === name));
    daftar.forEach(t => { const el = $('tab-' + t); if (el) el.classList.toggle('hide', t !== name); });
    if (typeof window.onTab === 'function') window.onTab(name);
  };
  bukaTab(awal);
}

/* ---------------- lencana notifikasi (khusus Kepala Admin) ---------------- */
async function hitungNotif() {
  if (!sb || !navigator.onLine) return 0;
  try {
    const { count } = await sb.from('notifikasi')
      .select('notif_id', { count: 'exact', head: true }).eq('status', 'baru');
    return count || 0;
  } catch (e) { return 0; }
}

if ('serviceWorker' in navigator) {
  addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {}));
}
