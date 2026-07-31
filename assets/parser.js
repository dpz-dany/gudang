// ============================================================================
//  Pembaca label pengiriman  v3
//
//  Mendukung dua tata letak, dikenali otomatis:
//    · SHOPEE / SPX  — kolom: #, Nama Produk, SKU, Variasi, Qty
//    · TIKTOK / Tokopedia (J&T dll) — kolom: Product Name, SKU, Seller SKU, Qty
//      HATI-HATI: di label TikTok kolom "SKU" berisi VARIASI.
//      SKU yang sebenarnya ada di kolom "Seller SKU", dan sering kosong.
//
//  Sudah diuji terhadap berkas asli untuk:
//    · banyak barang dalam satu label
//    · SKU / variasi / nama produk yang terpotong ke baris berikutnya
//    · satu kiriman tumpah ke halaman kedua (halaman lanjutan tanpa kop)
//    · deretan nomor resi miring di pinggir label yang mengacaukan teks
//    · label yang SAMA SEKALI tidak mencetak SKU
//    · label yang huruf-hurufnya terpecah ("Pe ne rima :")
//    · "Qty Total" pada label TikTok dipakai sebagai pemeriksa hasil baca
// ============================================================================

const ROW_TOL = 3.0;
const COL_TOL = 2.0;

// regex longgar: "Penerima" tetap cocok walau tercetak "Pe ne rima"
function luwes(kata) {
  return kata.split('').map(c => c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('\\s*');
}
// flag 'm' penting: nilai berhenti di ujung BARIS, bukan ujung seluruh teks
const R_PENERIMA = new RegExp(luwes('Penerima') + '\\s*:?\\s*(.{1,45}?)\\s*(?:\\(\\+?\\d|P\\s*e\\s*n\\s*g\\s*i|$)', 'im');
const R_PENGIRIM = new RegExp(luwes('Pengirim') + '\\s*:?\\s*(.{1,45}?)\\s*(?:\\(\\+?\\d|$)', 'im');
const R_PESANAN  = new RegExp('(?:' + luwes('No.Pesanan') + '|Order\\s*Id)\\s*:?\\s*([A-Z0-9]{8,})', 'i');
const R_BATAS    = new RegExp(luwes('BatasKirim') + '\\s*:?\\s*(\\d{2})-(\\d{2})-(\\d{4})', 'i');
const R_SHIP     = /\bShip\s*:?\s*(\d{2})-(\d{2})-(\d{4})/i;
const R_NICK     = /NickName\s*:?\s*(\S{1,40})/i;
const R_RESI     = /\b(SPX[A-Z]{2}\d{8,}|J[A-Z]\d{8,}|[A-Z]{2,3}\d{9,16})\b/;

const BARIS_STOP = /^(Pesan\s*:|Qty\s*Total|Order\s*ID\s*:|NickName|In\s*transit)/i;

function parseLabelPages(pages) {
  return gabungLanjutan(pages.map((p, i) => bacaHalaman(p, i + 1)));
}

/* -------------------- satu halaman fisik -------------------- */
function bacaHalaman(page, pageNo) {
  const items = page.items
    .filter(it => String(it.str).trim() && !it.rot)          // buang teks miring di pinggir
    .map(it => ({ text: String(it.str), x: it.x, x1: it.x + (it.width || 0), top: page.height - it.y }))
    .sort((a, b) => (a.top - b.top) || (a.x - b.x));

  const rows = [];
  for (const it of items) {
    let r = rows.find(r => Math.abs(r.top - it.top) <= ROW_TOL);
    if (!r) { r = { top: it.top, cells: [] }; rows.push(r); }
    r.cells.push(it);
  }
  rows.sort((a, b) => a.top - b.top);
  for (const r of rows) { r.cells.sort((a, b) => a.x - b.x); r.text = gabungSel(r.cells); }

  const kop    = cariKop(rows);
  const kepala = bacaKepala(rows, kop ? kop.top : Infinity);
  const kaki   = bacaKaki(rows, kop ? kop.top : 0);

  if (kaki.order_sn)    kepala.order_sn    = kepala.order_sn    || kaki.order_sn;
  if (kaki.tracking_no) kepala.tracking_no = kepala.tracking_no || kaki.tracking_no;
  if (kaki.nickname)    kepala.nickname    = kepala.nickname    || kaki.nickname;

  const semua = rows.map(r => r.text).join(' ');
  return {
    pageNo,
    platform: kop ? kop.platform : (/tokopedia|NickName|Seller\s*SKU/i.test(semua) ? 'tiktok' : 'shopee'),
    hasKop  : !!(kepala._adaPenerima || kepala._adaResi || kepala._adaJnt),
    hasTabel: !!kop,
    qty_total: kaki.qty_total,
    ...kepala,
    items: kop ? bacaTabel(rows, kop) : []
  };
}

function gabungSel(cells) {
  let out = '';
  for (let i = 0; i < cells.length; i++) {
    if (i && cells[i].x - cells[i - 1].x1 > 0.6) out += ' ';
    out += cells[i].text;
  }
  return out.replace(/\s+/g, ' ').trim();
}

/* -------------------- kop tabel + peta kolom -------------------- */
function cariKop(rows) {
  for (const r of rows) {
    if (!r.cells.some(c => /^Qty$/i.test(c.text.trim()))) continue;
    const teks   = r.text.replace(/\s+/g, ' ');
    const tiktok = /Seller\s*SKU/i.test(teks);
    const shopee = /Variasi/i.test(teks);
    if (!tiktok && !shopee) continue;

    // tiap sel kop menandai TEPI KIRI kolomnya
    const tepi = r.cells.map(c => ({ x: c.x, t: c.text.trim() })).sort((a, b) => a.x - b.x);
    const band = [];
    for (const e of tepi) {
      let p = null;
      if      (/^#$/.test(e.t))                p = 'no';
      else if (/^(Nama|Product)/i.test(e.t))   p = 'nama';
      else if (/^Seller\s*SKU$/i.test(e.t))    p = 'sku';
      else if (/^Variasi$/i.test(e.t))         p = 'var';
      else if (/^SKU$/i.test(e.t))             p = tiktok ? 'var' : 'sku';
      else if (/^Qty$/i.test(e.t))             p = 'qty';
      if (p && !band.some(b => b.peran === p)) band.push({ peran: p, dari: e.x, sampai: Infinity });
    }
    band.sort((a, b) => a.dari - b.dari);
    for (let i = 0; i < band.length - 1; i++) band[i].sampai = band[i + 1].dari;
    if (!band.some(b => b.peran === 'qty')) continue;

    return { top: r.top, band, platform: tiktok ? 'tiktok' : 'shopee',
             punyaNo: band.some(b => b.peran === 'no') };
  }
  return null;
}

/* -------------------- keterangan di atas tabel -------------------- */
function bacaKepala(rows, tableTop) {
  const atas = rows.filter(r => r.top < tableTop);
  const flat = atas.map(r => r.text).join(' \n ');
  const g = re => { const m = flat.match(re); return m ? m[1].trim() : null; };

  let tracking_no = g(R_RESI);
  if (!tracking_no) {
    const sendiri = atas.find(r => /^[A-Z]{2,3}\d{8,16}$/.test(r.text.trim()));
    if (sendiri) tracking_no = sendiri.text.trim();
  }

  const d = flat.match(R_BATAS)
         || flat.match(/(\d{2})-(\d{2})-(\d{4})\s*B\s*a\s*t\s*a\s*s/i)
         || flat.match(R_SHIP);

  return {
    order_sn   : g(R_PESANAN),
    tracking_no,
    buyer_name : g(R_PENERIMA),
    sender_name: g(R_PENGIRIM),
    nickname   : g(R_NICK),
    ship_by    : d ? `${d[3]}-${d[2]}-${d[1]}` : null,
    service    : g(/\b(STD|ECO|NDD|SAMEDAY|INSTANT|NEXTDAY|REG)\b/),
    _adaPenerima: R_PENERIMA.test(flat),
    _adaResi    : /R\s*e\s*s\s*i\s*:/i.test(flat),
    _adaJnt     : /J&T|jet\.co\.id/i.test(flat)
  };
}

/* -------------------- keterangan di bawah tabel -------------------- */
function bacaKaki(rows, tableTop) {
  const out = {};
  for (const r of rows) {
    if (r.top <= tableTop) continue;
    let m = r.text.match(/Pesan\s*:?\s*\(([^()]+)\)\s*\(([^()]+)\)/i);
    if (m) { out.order_sn = out.order_sn || m[1].trim(); out.tracking_no = out.tracking_no || m[2].trim(); }
    m = r.text.match(/Order\s*ID\s*:?\s*([A-Z0-9]{8,})/i);
    if (m) out.order_sn = out.order_sn || m[1].trim();
    m = r.text.match(R_NICK);
    if (m) out.nickname = out.nickname || m[1].trim();
    m = r.text.match(/Qty\s*Total\s*:?\s*(\d+)/i);
    if (m) out.qty_total = parseInt(m[1], 10);
  }
  return out;
}

/* -------------------- isi tabel -------------------- */
function bacaTabel(rows, kop) {
  const kolom = x => {
    for (const b of kop.band) if (x >= b.dari - COL_TOL && x < b.sampai - COL_TOL) return b.peran;
    return null;
  };
  const strip = t => /^(SPX[A-Z]{2}\d{8,}|J[A-Z]\d{8,})(\s+\1)*$/.test(t.trim());

  const out = [];
  let cur = null;

  for (const r of rows) {
    if (r.top <= kop.top + COL_TOL) continue;
    if (BARIS_STOP.test(r.text)) break;
    if (strip(r.text)) continue;

    const by = { no: [], nama: [], sku: [], var: [], qty: [] };
    for (const c of r.cells) { const k = kolom(c.x); if (k) by[k].push(c); }

    const noTxt   = gabungSel(by.no);
    const namaTxt = gabungSel(by.nama);
    const qtyRaw  = gabungSel(by.qty).trim();
    const qtyTxt  = qtyRaw.replace(/\D/g, '');

    const baru = kop.punyaNo
      ? (/^\d+$/.test(noTxt) && !!qtyTxt)
      : (/^\d+$/.test(qtyRaw) && !!namaTxt);   // TikTok: tak ada kolom nomor urut

    if (baru) {
      cur = {
        line_no: kop.punyaNo ? parseInt(noTxt, 10) : out.length + 1,
        qty: parseInt(qtyTxt, 10),
        product_name: namaTxt,
        sku: gabungSel(by.sku),
        variation_name: gabungSel(by.var)
      };
      out.push(cur);
    } else if (cur) {
      const n = namaTxt, s = gabungSel(by.sku), v = gabungSel(by.var);
      if (n) cur.product_name += (cur.product_name ? ' ' : '') + n;
      if (s) cur.sku += s;                       // SKU selalu putus di tanda hubung
      if (v) cur.variation_name += (cur.variation_name ? ' ' : '') + v;
    }
  }

  for (const it of out) {
    it.product_name   = it.product_name.replace(/\s+/g, ' ').trim();
    it.sku            = it.sku.replace(/\s+/g, '').trim();
    it.variation_name = it.variation_name.replace(/\s+/g, ' ').trim() || null;
  }
  return out;
}

/* -------------------- sambung halaman lanjutan -------------------- */
function gabungLanjutan(mentah) {
  const out = [];
  for (const p of mentah) {
    const lanjutan = p.hasTabel && !p.hasKop &&
      (!p.order_sn || (out.length && out[out.length - 1].order_sn === p.order_sn));

    if (lanjutan && out.length) {
      const prev = out[out.length - 1];
      prev.order_sn    = prev.order_sn    || p.order_sn;
      prev.tracking_no = prev.tracking_no || p.tracking_no;
      prev.shop_name   = prev.shop_name   || p.nickname || p.sender_name;
      if (p.qty_total != null) prev.qty_total = p.qty_total;
      prev.items.push(...p.items);
      prev.pages.push(p.pageNo);
      continue;
    }
    out.push({
      platform: p.platform,
      order_sn: p.order_sn, tracking_no: p.tracking_no, buyer_name: p.buyer_name,
      shop_name: p.nickname || p.sender_name,   // TikTok: NickName · Shopee: Pengirim
      sender_name: p.sender_name, nickname: p.nickname,
      ship_by: p.ship_by, service: p.service, qty_total: p.qty_total,
      pages: [p.pageNo], items: p.items, warnings: []
    });
  }

  for (const o of out) {
    o.items.forEach((it, i) => it.line_no = i + 1);
    o.missing_sku = o.items.filter(i => !i.sku).length;

    if (o.missing_sku)
      o.warnings.push(o.missing_sku + ' dari ' + o.items.length + ' barang tidak mencetak SKU di label');
    if (!o.order_sn)     o.warnings.push('No. Pesanan tidak ditemukan');
    if (!o.tracking_no)  o.warnings.push('No. Resi tidak ditemukan');
    if (!o.items.length) o.warnings.push('Tidak ada barang terbaca');
    for (const i of o.items) if (!(i.qty > 0)) o.warnings.push('Qty tidak terbaca pada baris #' + i.line_no);

    // TikTok mencetak "Qty Total" — pakai sebagai pemeriksa hasil baca
    if (o.qty_total != null) {
      const jml = o.items.reduce((a, i) => a + (i.qty || 0), 0);
      if (jml !== o.qty_total)
        o.warnings.push('Jumlah terbaca ' + jml + ' tidak sama dengan "Qty Total: ' + o.qty_total +
                        '" di label — kemungkinan ada halaman yang hilang');
    }
  }
  return out;
}

if (typeof module !== 'undefined') module.exports = { parseLabelPages };

/* ==================== pembacaan PDF di browser ==================== */
const PDF_WORKER = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.worker.min.js';
let _wrk = null;
function siapkanWorker() {
  if (_wrk) return _wrk;
  _wrk = (async () => {
    try {
      const src = await (await fetch(PDF_WORKER)).text();
      pdfjsLib.GlobalWorkerOptions.workerSrc =
        URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    } catch (e) { pdfjsLib.GlobalWorkerOptions.workerSrc = PDF_WORKER; }
  })();
  return _wrk;
}

async function bacaPDF(file, onProgress) {
  await siapkanWorker();
  const doc = await pdfjsLib.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
  const pages = [];
  for (let p = 1; p <= doc.numPages; p++) {
    const pg = await doc.getPage(p);
    const vp = pg.getViewport({ scale: 1 });
    const tc = await pg.getTextContent();
    pages.push({
      width: vp.width, height: vp.height,
      items: tc.items.filter(i => i.str).map(i => ({
        str: i.str, x: i.transform[4], y: i.transform[5], width: i.width,
        rot: !(Math.abs(i.transform[1]) < 0.01 && Math.abs(i.transform[2]) < 0.01)
      }))
    });
    if (onProgress && p % 10 === 0) { onProgress(p, doc.numPages); await new Promise(r => setTimeout(r)); }
  }
  if (onProgress) onProgress(doc.numPages, doc.numPages);
  return parseLabelPages(pages);
}
