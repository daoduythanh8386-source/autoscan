/* APP scan PDF – trình tạo PDF tối giản, không thư viện ngoài.
 * Mỗi trang 1 ảnh: JPEG nhúng nguyên (DCTDecode, không nén lại) hoặc RGB lossless
 * nén Flate qua CompressionStream. */
(function (root) {
  'use strict';
  const enc = new TextEncoder();
  const SIZES = { a4: [595.28, 841.89], a5: [419.53, 595.28], letter: [612, 792] };

  async function deflate(bytes) {
    if (typeof CompressionStream === 'undefined') return null;
    const cs = new CompressionStream('deflate');
    const stream = new Blob([bytes]).stream().pipeThrough(cs);
    return new Uint8Array(await new Response(stream).arrayBuffer());
  }

  /**
   * pages: [{ w, h, jpeg?: Uint8Array, rgb?: Uint8Array }]
   * opts: { size: 'auto'|'a4'|'a5'|'letter', title, author }
   * Trả về Blob application/pdf.
   */
  async function build(pages, opts = {}) {
    const parts = [], offsets = [];
    let pos = 0;
    const push = (x) => { const b = typeof x === 'string' ? enc.encode(x) : x; parts.push(b); pos += b.length; };
    // Đối tượng: 1 Catalog, 2 Pages, 3 đối tượng mỗi trang, 1 Info → bảng xref có nObj mục (kể cả 0)
    const nObj = 2 + pages.length * 3 + 2;
    const obj = (n, body, stream) => {
      offsets[n] = pos;
      push(`${n} 0 obj\n`);
      push(body);
      if (stream) { push('\nstream\n'); push(stream); push('\nendstream'); }
      push('\nendobj\n');
    };
    push('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
    const kids = pages.map((_, i) => `${3 + i * 3} 0 R`).join(' ');
    obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
    obj(2, `<< /Type /Pages /Count ${pages.length} /Kids [${kids}] >>`);
    for (let i = 0; i < pages.length; i++) {
      const pg = pages[i], pn = 3 + i * 3;
      let pw, ph;
      if (opts.size && SIZES[opts.size]) {
        [pw, ph] = SIZES[opts.size];
        if (pg.w > pg.h) [pw, ph] = [ph, pw];
      } else { pw = pg.w / 300 * 72; ph = pg.h / 300 * 72; }
      const s = Math.min(pw / pg.w, ph / pg.h), dw = pg.w * s, dh = pg.h * s, ox = (pw - dw) / 2, oy = (ph - dh) / 2;
      let img, filter;
      if (pg.jpeg) { img = pg.jpeg; filter = '/DCTDecode'; }
      else { img = await deflate(pg.rgb); filter = '/FlateDecode'; if (!img) throw new Error('Trình duyệt không hỗ trợ nén lossless'); }
      obj(pn, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pw.toFixed(2)} ${ph.toFixed(2)}] /Resources << /XObject << /Im${i} ${pn + 2} 0 R >> >> /Contents ${pn + 1} 0 R >>`);
      const content = enc.encode(`q ${dw.toFixed(3)} 0 0 ${dh.toFixed(3)} ${ox.toFixed(3)} ${oy.toFixed(3)} cm /Im${i} Do Q`);
      obj(pn + 1, `<< /Length ${content.length} >>`, content);
      obj(pn + 2, `<< /Type /XObject /Subtype /Image /Width ${pg.w} /Height ${pg.h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter ${filter} /Length ${img.length} >>`, img);
    }
    const esc = (t) => (t || '').replace(/[\\()]/g, '\\$&');
    // Chuỗi Unicode (UTF-16BE) cho tiêu đề tiếng Việt
    const u16 = (t) => { let h = 'FEFF'; for (const ch of t || '') { const c = ch.charCodeAt(0); h += c.toString(16).padStart(4, '0').toUpperCase(); } return `<${h}>`; };
    obj(nObj - 1, `<< /Title ${u16(opts.title || 'APP scan PDF')} /Author ${u16(opts.author || 'APP scan PDF')} /Creator (${esc('APP scan PDF - Dao Duy Thanh')}) /Producer (APP scan PDF web) >>`);
    const xref = pos;
    let x = `xref\n0 ${nObj}\n0000000000 65535 f \n`;
    for (let n = 1; n < nObj; n++) x += String(offsets[n] || 0).padStart(10, '0') + ' 00000 n \n';
    push(x);
    push(`trailer\n<< /Size ${nObj} /Root 1 0 R /Info ${nObj - 1} 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
    return new Blob(parts, { type: 'application/pdf' });
  }

  const API = { build, SIZES };
  if (typeof module !== 'undefined' && module.exports) module.exports = API; else root.PDFW = API;
})(typeof self !== 'undefined' ? self : this);
