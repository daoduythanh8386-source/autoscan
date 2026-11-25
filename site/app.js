/* APP scan PDF – bản web 1.0 (luồng như CamScanner).
 * Chụp → Cắt → Bộ lọc → Tài liệu → PDF/Chia sẻ. App làm bởi Đào Duy Thanh, © since 2026.
 * Toàn bộ xử lý trên máy (Web Worker); giới hạn độ phân giải để chạy ổn định trên điện thoại. */
(() => {
  'use strict';
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => [...document.querySelectorAll(s)];
  const WORK = 2000;   // ảnh dùng để nhận diện/nắn cong
  const VIEW = 1400;   // ảnh hiển thị khi cắt & chọn bộ lọc
  const OUT = 3508;    // ảnh kết quả (A4 @ 300 DPI)
  const THUMB = 420;
  const FILTERS = [
    { id: 'auto', label: 'Tự động', p: { mode: 'document', shadow: 1, brightness: 0, contrast: 0, sharpness: 0.15, deshadow: true } },
    { id: 'magic', label: 'Magic Color', p: { mode: 'magic', shadow: 1, brightness: 0, contrast: 0, sharpness: 0.35, deshadow: true } },
    { id: 'light', label: 'Làm sáng', p: { mode: 'light', shadow: 1, brightness: 0, contrast: 0, sharpness: 0.15, deshadow: true } },
    { id: 'original', label: 'Gốc', p: { mode: 'original', shadow: 0, brightness: 0, contrast: 0, sharpness: 0, deshadow: false } },
    { id: 'gray', label: 'Xám', p: { mode: 'gray', shadow: 1, brightness: 0, contrast: 0, sharpness: 0.15, deshadow: true } },
    { id: 'bw', label: 'Trắng đen', p: { mode: 'bw', shadow: 1, brightness: 0, contrast: 0, sharpness: 0, deshadow: true } },
  ];
  const PAGE_SIZES = [['a4', 'A4'], ['auto', 'Theo tài liệu'], ['letter', 'Letter']];

  // ------------------------------------------------------------ lỗi chung: báo, không làm treo app
  window.addEventListener('error', (e) => toast('Lỗi: ' + (e.message || 'không xác định'), 4000));
  window.addEventListener('unhandledrejection', (e) => toast('Lỗi: ' + ((e.reason && e.reason.message) || e.reason || 'không xác định'), 4000));

  // ------------------------------------------------------------ tiện ích UI
  let toastTimer;
  function toast(msg, ms = 2600) {
    const t = $('#toast'); t.textContent = msg; t.classList.add('show');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), ms);
  }
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  function sheet(html) { $('#sheet').innerHTML = html; $('#modal').classList.remove('hidden'); return $('#sheet'); }
  const closeSheet = () => $('#modal').classList.add('hidden');
  $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeSheet(); });
  function ask(title, msg, ok = 'Đồng ý', cancel = 'Huỷ', danger = false) {
    return new Promise((res) => {
      const s = sheet(`<h3>${esc(title)}</h3><div class="muted">${msg}</div><div class="btns">
        ${cancel ? `<button class="btn outline" data-r="0">${esc(cancel)}</button>` : ''}<button class="btn ${danger ? 'danger' : ''}" data-r="1">${esc(ok)}</button></div>`);
      s.querySelectorAll('[data-r]').forEach((b) => b.onclick = () => { closeSheet(); res(b.dataset.r === '1'); });
    });
  }
  function promptText(title, value) {
    return new Promise((res) => {
      const s = sheet(`<h3>${esc(title)}</h3><input class="input" id="pIn" value="${esc(value || '')}">
        <div class="btns"><button class="btn outline" data-r="0">Huỷ</button><button class="btn" data-r="1">Lưu</button></div>`);
      const inp = s.querySelector('#pIn'); setTimeout(() => inp.focus(), 60);
      s.querySelectorAll('[data-r]').forEach((b) => b.onclick = () => { closeSheet(); res(b.dataset.r === '1' && inp.value.trim() ? inp.value.trim() : null); });
    });
  }
  function menu(title, items) {
    return new Promise((res) => {
      const s = sheet(`<h3>${esc(title)}</h3>${items.map(([k, ic, l, d]) => `<button class="menu-item${d ? ' danger' : ''}" data-k="${k}"><i>${ic}</i>${esc(l)}</button>`).join('')}`);
      s.querySelectorAll('[data-k]').forEach((b) => b.onclick = () => { closeSheet(); res(b.dataset.k); });
    });
  }
  function progress(title) {
    const s = sheet(`<h3>${esc(title)}</h3><div class="muted" id="pgTxt">Đang chuẩn bị…</div><div class="progress"><i id="pgBar"></i></div>`);
    return { set(t, f) { s.querySelector('#pgTxt').textContent = t; s.querySelector('#pgBar').style.width = `${Math.round(f * 100)}%`; }, close: closeSheet };
  }
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2));
  const two = (n) => String(n).padStart(2, '0');
  const defaultName = (d = new Date()) => `Scan ${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}h${two(d.getMinutes())}`;
  const sanitize = (s) => (s || 'TaiLieu').replace(/[\\/:*?"<>|\x00-\x1F]/g, '_').replace(/\s+/g, ' ').trim().slice(0, 120) || 'TaiLieu';
  const fmtDate = (t) => { const d = new Date(t); return `${two(d.getDate())}/${two(d.getMonth() + 1)}/${d.getFullYear()}`; };
  const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ------------------------------------------------------------ cài đặt
  const KEY = 'appscanpdf.settings';
  const S = Object.assign({ auto: true, grid: true, filter: 'auto', page: 'a4' }, (() => { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; } })());
  if (S.filter === 'bright') S.filter = 'light';
  const saveS = () => { try { localStorage.setItem(KEY, JSON.stringify(S)); } catch { /* riêng tư */ } };

  // ------------------------------------------------------------ IndexedDB (ảnh lưu dạng byte – ổn định trên Safari)
  const DB = (() => {
    let dbp;
    const open = () => dbp || (dbp = new Promise((res, rej) => {
      const r = indexedDB.open('appscanpdf', 1);
      r.onupgradeneeded = () => { const db = r.result; db.createObjectStore('docs', { keyPath: 'id' }); db.createObjectStore('pages', { keyPath: 'id' }).createIndex('docId', 'docId'); };
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
    }));
    const tx = async (store, mode, fn) => {
      const db = await open();
      return new Promise((res, rej) => {
        const t = db.transaction(store, mode), st = t.objectStore(store); let out;
        const r = fn(st); if (r) r.onsuccess = () => { out = r.result; };
        t.oncomplete = () => res(out); t.onerror = () => rej(t.error); t.onabort = () => rej(t.error || new Error('Bộ nhớ trình duyệt đầy'));
      });
    };
    return {
      put: (s, v) => tx(s, 'readwrite', (st) => st.put(v)),
      get: (s, id) => tx(s, 'readonly', (st) => st.get(id)),
      del: (s, id) => tx(s, 'readwrite', (st) => st.delete(id)),
      all: (s) => tx(s, 'readonly', (st) => st.getAll()),
      pagesOf: async (docId) => (await tx('pages', 'readonly', (st) => st.index('docId').getAll(docId))).sort((a, b) => a.idx - b.idx),
    };
  })();

  // ------------------------------------------------------------ worker
  function makeWorker() {
    let w, seq = 0; const pend = new Map();
    const start = () => {
      w = new Worker('worker.js');
      w.onmessage = (e) => { const p = pend.get(e.data.id); if (!p) return; pend.delete(e.data.id); e.data.error ? p.rej(new Error(e.data.error)) : p.res(e.data.result); };
      w.onerror = (e) => { e.preventDefault && e.preventDefault(); for (const p of pend.values()) p.rej(new Error('Bộ xử lý ảnh gặp lỗi – thử lại')); pend.clear(); w.terminate(); start(); };
    };
    start();
    return { call(op, data = {}, tr = []) { const id = ++seq; return new Promise((res, rej) => { pend.set(id, { res, rej }); w.postMessage(Object.assign({ id, op }, data), tr); }); } };
  }
  const heavy = makeWorker(), live = makeWorker();

  // ------------------------------------------------------------ ảnh
  const pageBlob = (p) => p.bytes ? new Blob([p.bytes], { type: p.type || 'image/jpeg' }) : p.blob;
  function loadImg(blob) {
    return new Promise((res, rej) => {
      const url = URL.createObjectURL(blob), im = new Image();
      im.onload = () => { URL.revokeObjectURL(url); res(im); };
      im.onerror = () => { URL.revokeObjectURL(url); rej(new Error('Không đọc được ảnh')); };
      im.src = url;
    });
  }
  /** Giải mã ảnh, thu nhỏ về tối đa maxSide (KHÔNG bao giờ giải mã quá lớn → tránh tràn bộ nhớ). */
  async function decode(src, maxSide) {
    const blob = src instanceof Blob ? src : pageBlob(src);
    if (!blob) throw new Error('Thiếu dữ liệu ảnh');
    let bmp;
    try { bmp = await createImageBitmap(blob, { imageOrientation: 'from-image' }); }
    catch { try { bmp = await createImageBitmap(blob); } catch { bmp = await loadImg(blob); } }
    const fullW = bmp.naturalWidth || bmp.width, fullH = bmp.naturalHeight || bmp.height;
    const s = Math.min(1, maxSide / Math.max(fullW, fullH));
    const w = Math.max(1, Math.round(fullW * s)), h = Math.max(1, Math.round(fullH * s));
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.imageSmoothingQuality = 'high'; ctx.drawImage(bmp, 0, 0, w, h); bmp.close && bmp.close();
    const rgba = ctx.getImageData(0, 0, w, h).data;
    c.width = c.height = 0;
    return { rgba, w, h, fullW, fullH, scale: w / fullW };
  }
  function toCanvas(rgba, w, h, canvas) {
    const c = canvas || document.createElement('canvas'); c.width = w; c.height = h;
    c.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer || rgba, rgba.byteOffset || 0, w * h * 4), w, h), 0, 0);
    return c;
  }
  const toBlob = (c, type, q) => new Promise((res, rej) => c.toBlob((b) => b ? res(b) : rej(new Error('Không mã hoá được ảnh (thiếu bộ nhớ)')), type, q));
  function shrinkCanvas(src, maxSide) {
    const s = Math.min(1, maxSide / Math.max(src.width, src.height)), c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(src.width * s)); c.height = Math.max(1, Math.round(src.height * s));
    const ctx = c.getContext('2d'); ctx.imageSmoothingQuality = 'high'; ctx.drawImage(src, 0, 0, c.width, c.height); return c;
  }
  const scaleQ = (q, s) => q && q.map((p) => ({ x: p.x * s, y: p.y * s }));
  function scaleModel(m, s) {
    if (!m || s === 1) return m;
    const j = JSON.parse(JSON.stringify(m));
    if (j.type === 'coons') j.quad = scaleQ(j.quad, s);
    if (j.type === 'cyl') { j.f *= s; j.cx *= s; j.cy *= s; }
    return j;
  }
  /** Tham số chỉnh sửa (toạ độ ảnh gốc) → toạ độ ảnh đã thu nhỏ theo hệ số s. */
  function paramsAt(e, s) {
    const p = Object.assign({ paper: 'auto' }, e);
    p.corners = scaleQ(e.corners, s); p.dewarp = scaleModel(e.dewarp, s);
    return p;
  }
  const FALIAS = { bright: 'light' };
  const filterParams = (id) => (FILTERS.find((f) => f.id === (FALIAS[id] || id)) || FILTERS[0]).p;

  // ------------------------------------------------------------ điều hướng
  const stack = ['home'];
  const onShow = {}, onLeave = {};
  function show(id, push = true) {
    const cur = stack[stack.length - 1];
    if (cur !== id && onLeave[cur]) onLeave[cur]();
    $$('.screen').forEach((s) => s.classList.toggle('active', s.id === id));
    if (push) { stack.push(id); history.pushState({ s: id }, ''); }
    if (onShow[id]) onShow[id]();
  }
  /** Thay màn hiện tại (không tạo bước quay lại). */
  function replace(id) { stack[stack.length - 1] = id; show(id, false); }
  function back() {
    if (!$('#modal').classList.contains('hidden')) { closeSheet(); return; }
    if (stack.length > 1) { const cur = stack.pop(); if (onLeave[cur]) onLeave[cur](); const prev = stack[stack.length - 1]; $$('.screen').forEach((s) => s.classList.toggle('active', s.id === prev)); if (onShow[prev]) onShow[prev](); }
  }
  window.addEventListener('popstate', () => { back(); if (stack.length === 1) history.pushState({ s: 'home' }, ''); });
  history.replaceState({ s: 'home' }, ''); history.pushState({ s: 'home' }, '');
  $$('[data-back]').forEach((b) => b.onclick = () => history.back());
  $$('[data-go]').forEach((b) => b.onclick = () => show(b.dataset.go));
  /** Về thẳng màn tài liệu, xoá các bước trung gian (camera/cắt/lọc) khỏi lịch sử. */
  function goDoc() {
    while (stack.length > 1 && stack[stack.length - 1] !== 'home') { const s = stack.pop(); if (onLeave[s]) onLeave[s](); }
    show('doc');
  }

  // ------------------------------------------------------------ tài liệu & trang
  let curDoc = null;
  async function newDoc() { const d = { id: uid(), name: defaultName(), createdAt: Date.now(), updatedAt: Date.now() }; await DB.put('docs', d); return d; }
  async function touch(d) { d.updatedAt = Date.now(); await DB.put('docs', d); }
  const urls = new Map();
  function thumbURL(p) {
    const k = p.id + ':' + (p.ver || 0);
    if (!urls.has(k) && p.thumbBytes) urls.set(k, URL.createObjectURL(new Blob([p.thumbBytes], { type: 'image/jpeg' })));
    return urls.get(k) || 'icons/icon-192.png';
  }

  /** Lưu ảnh mới (byte gốc nguyên vẹn) + phân tích ở WORK px. */
  async function addPage(doc, blob) {
    const bytes = await blob.arrayBuffer(), type = blob.type || 'image/jpeg';
    const img = await decode(new Blob([bytes], { type }), WORK);
    const n = (await DB.pagesOf(doc.id)).length;
    const page = { id: uid(), docId: doc.id, idx: n, bytes, type, w: img.fullW, h: img.fullH, ver: 0, createdAt: Date.now(),
      edit: Object.assign({ filter: S.filter, rotation: 0, fineRotation: 0, paper: 'auto' }, filterParams(S.filter)) };
    await DB.put('pages', page); // lưu ngay – không mất ảnh nếu trình duyệt bị đóng
    const r = await heavy.call('ingest', { rgba: img.rgba, w: img.w, h: img.h, mode: page.edit.mode }, [img.rgba.buffer]);
    const sc = 1 / img.scale, a = r.analysis;
    page.auto = { corners: scaleQ(a.corners || a.suggest, sc), dewarp: scaleModel(a.dewarp, sc), sure: !!a.corners, kind: a.kind };
    page.edit.corners = page.auto.corners; page.edit.dewarp = page.auto.dewarp;
    page.issues = a.issues;
    page.thumbBytes = await (await toBlob(toCanvas(r.thumb.rgba, r.thumb.w, r.thumb.h), 'image/jpeg', 0.8)).arrayBuffer();
    page.ver = 1; page.dirty = true;
    await DB.put('pages', page); await touch(doc);
    return page;
  }
  /** Dựng ảnh kết quả (OUT px) + ảnh thu nhỏ; lưu lại để xuất PDF tức thì. */
  async function finalize(page) {
    const img = await decode(page, OUT);
    const o = await heavy.call('render', { rgba: img.rgba, w: img.w, h: img.h, params: paramsAt(page.edit, img.scale), scale: 1, bicubic: true }, [img.rgba.buffer]);
    let c = toCanvas(o.rgba, o.w, o.h);
    page.outBytes = await (await toBlob(c, 'image/jpeg', 0.92)).arrayBuffer(); page.outW = o.w; page.outH = o.h;
    page.thumbBytes = await (await toBlob(shrinkCanvas(c, THUMB), 'image/jpeg', 0.8)).arrayBuffer();
    c.width = c.height = 0; c = null;
    page.ver = (page.ver || 0) + 1; page.dirty = false;
    await DB.put('pages', page);
  }

  // ------------------------------------------------------------ TRANG CHỦ
  onShow.home = async () => {
    const q = ($('#search').value || '').toLowerCase().trim();
    const docs = (await DB.all('docs')).sort((a, b) => b.updatedAt - a.updatedAt);
    const grid = $('#docGrid'); grid.innerHTML = '';
    let shown = 0;
    for (const d of docs) {
      const pages = await DB.pagesOf(d.id);
      if (!pages.length) { if (Date.now() - d.createdAt > 60000) await DB.del('docs', d.id); continue; }
      if (q && !d.name.toLowerCase().includes(q)) continue;
      shown++;
      const el = document.createElement('div'); el.className = 'doc-card';
      el.innerHTML = `<img class="th" src="${thumbURL(pages[0])}" alt=""><span class="badge">${pages.length} trang</span>
        <button class="more" aria-label="Tuỳ chọn">⋯</button><b>${esc(d.name)}</b><small>${fmtDate(d.updatedAt)}</small>`;
      el.onclick = () => { curDoc = d; show('doc'); };
      el.querySelector('.more').onclick = async (e) => {
        e.stopPropagation();
        const k = await menu(d.name, [['share', '📤', 'Chia sẻ PDF'], ['pdf', '📄', 'Lưu PDF'], ['rename', '✏️', 'Đổi tên'], ['del', '🗑', 'Xoá tài liệu', true]]);
        if (k === 'rename') { const n = await promptText('Đổi tên tài liệu', d.name); if (n) { d.name = n; await touch(d); onShow.home(); } }
        if (k === 'del' && await ask('Xoá tài liệu?', `Xoá “${esc(d.name)}” và ${pages.length} trang khỏi máy.`, 'Xoá', 'Huỷ', true)) {
          for (const p of pages) await DB.del('pages', p.id); await DB.del('docs', d.id); onShow.home();
        }
        if (k === 'share' || k === 'pdf') { curDoc = d; await Export.pdf(k === 'share'); }
      };
      grid.appendChild(el);
    }
    $('#empty').classList.toggle('hidden', shown > 0 || !!q);
  };
  $('#search').oninput = () => onShow.home();
  $('#btnScan').onclick = async () => { curDoc = await newDoc(); Cam.reset(); show('camera'); };
  $('#fileImport').onchange = async (e) => {
    const files = [...e.target.files]; e.target.value = ''; if (!files.length) return;
    curDoc = await newDoc(); const pages = await importFiles(files); if (pages.length) Flow.start(pages);
  };
  async function importFiles(files) {
    const pg = progress(`Đang nhập ${files.length} ảnh`), out = [];
    for (let i = 0; i < files.length; i++) {
      pg.set(`Ảnh ${i + 1}/${files.length}`, i / files.length);
      try { out.push(await addPage(curDoc, files[i])); } catch (e) { toast(`${files[i].name}: ${e.message}`, 4000); }
      await sleep(30);
    }
    pg.close(); return out;
  }
  // Trình duyệt trong Zalo/Facebook: camera hay lỗi → nhắc mở bằng Safari/Chrome
  if (/Zalo|FBAN|FBAV|Instagram|Line\//i.test(navigator.userAgent)) $('#inapp').classList.remove('hidden');
  $('#copyLink').onclick = async () => { try { await navigator.clipboard.writeText(location.href); toast('Đã sao chép link – dán vào Safari/Chrome'); } catch { toast(location.href, 5000); } };

  // ------------------------------------------------------------ CAMERA
  const Cam = (() => {
    let stream = null, track = null, ic = null, running = false, busy = false, capturing = false, timer = null, torch = false;
    let tracker = CV.Tracker(6), lastDet = null, lastSharp = 0, hist = [], cooldown = 0, mode = 'single', batch = [];
    const video = $('#video'), overlay = $('#overlay'), small = document.createElement('canvas');
    const sctx = small.getContext('2d', { willReadFrequently: true });
    function reset() { batch = []; }
    async function start() {
      $('#camAuto').classList.toggle('off', !S.auto);
      updBottom();
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { $('#camHint').textContent = 'Trình duyệt không hỗ trợ camera – dùng 🖼️ để nhập ảnh.'; return; }
      $('#camHint').textContent = 'Đang mở camera…';
      try {
        // 2560×1920 (4:3): đủ nét cho tài liệu, nhẹ hơn nhiều so với 4K → ổn định trên điện thoại
        stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 2560 }, height: { ideal: 1920 } } });
      } catch (e) {
        $('#camHint').textContent = e.name === 'NotAllowedError' ? 'Chưa cho phép camera. Vào cài đặt trình duyệt để cho phép, hoặc dùng 🖼️ nhập ảnh.' : 'Không mở được camera – dùng 🖼️ để nhập ảnh.';
        return;
      }
      track = stream.getVideoTracks()[0]; video.srcObject = stream;
      try { await video.play(); } catch { /* đã có thao tác người dùng */ }
      try { ic = 'ImageCapture' in window ? new ImageCapture(track) : null; } catch { ic = null; }
      const caps = track.getCapabilities ? track.getCapabilities() : {};
      $('#camTorch').hidden = !caps.torch;
      try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch { /* bỏ qua */ }
      running = true; tracker.reset(); loop();
    }
    function stop() {
      running = false; clearTimeout(timer);
      if (stream) stream.getTracks().forEach((t) => t.stop());
      stream = track = ic = null; video.srcObject = null;
    }
    function rect() {
      const cw = overlay.clientWidth, ch = overlay.clientHeight, vw = video.videoWidth || 1, vh = video.videoHeight || 1, s = Math.min(cw / vw, ch / vh);
      return { x: (cw - vw * s) / 2, y: (ch - vh * s) / 2, w: vw * s, h: vh * s };
    }
    function draw() {
      const dpr = Math.min(2, window.devicePixelRatio || 1), cw = overlay.clientWidth, ch = overlay.clientHeight;
      if (overlay.width !== Math.round(cw * dpr)) { overlay.width = Math.round(cw * dpr); overlay.height = Math.round(ch * dpr); }
      const ctx = overlay.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, cw, ch);
      const r = rect();
      if (S.grid) {
        ctx.strokeStyle = 'rgba(255,255,255,.3)'; ctx.lineWidth = 1; ctx.beginPath();
        for (let i = 1; i < 3; i++) { ctx.moveTo(r.x + r.w * i / 3, r.y); ctx.lineTo(r.x + r.w * i / 3, r.y + r.h); ctx.moveTo(r.x, r.y + r.h * i / 3); ctx.lineTo(r.x + r.w, r.y + r.h * i / 3); }
        ctx.stroke();
        let fw = r.w * 0.84, fh = fw * 1.4142; if (fh > r.h * 0.92) { fh = r.h * 0.92; fw = fh / 1.4142; }
        const L = fw * 0.1, x0 = r.x + (r.w - fw) / 2, y0 = r.y + (r.h - fh) / 2;
        ctx.strokeStyle = 'rgba(255,255,255,.8)'; ctx.lineWidth = 3; ctx.beginPath();
        for (const [px, py, dx, dy] of [[x0, y0, 1, 1], [x0 + fw, y0, -1, 1], [x0 + fw, y0 + fh, -1, -1], [x0, y0 + fh, 1, -1]]) { ctx.moveTo(px + L * dx, py); ctx.lineTo(px, py); ctx.lineTo(px, py + L * dy); }
        ctx.stroke();
      }
      const q = tracker.quad;
      if (q) {
        const pr = tracker.progress, col = pr >= 1 ? '#3ee6a0' : `rgba(${Math.round(255 - 180 * pr)},${Math.round(190 + 40 * pr)},${Math.round(70 + 90 * pr)},1)`;
        ctx.beginPath(); q.forEach((p, i) => { const X = r.x + p.x * r.w, Y = r.y + p.y * r.h; i ? ctx.lineTo(X, Y) : ctx.moveTo(X, Y); }); ctx.closePath();
        ctx.fillStyle = 'rgba(62,230,160,.16)'; ctx.fill(); ctx.strokeStyle = col; ctx.lineWidth = 3; ctx.stroke();
      }
    }
    function hint() {
      const d = lastDet;
      if (!d || !d.quad) return 'Đưa trọn tờ giấy vào khung';
      if (d.issues.includes('corner_out_of_frame')) return 'Lùi máy ra – góc giấy bị ra ngoài khung';
      if (d.issues.includes('too_small')) return 'Đưa máy lại gần hơn';
      if (d.issues.includes('low_contrast')) return 'Đặt giấy trên nền tối hơn';
      if (lastSharp < 18) return 'Giữ chắc tay…';
      if (!d.reliable) return 'Đang tìm tài liệu…';
      return S.auto ? 'Giữ yên – đang tự chụp' : 'Đã thấy tài liệu – bấm chụp';
    }
    async function loop() {
      if (!running) return;
      timer = setTimeout(loop, 110); draw();
      if (busy || capturing || !video.videoWidth) return;
      busy = true;
      try {
        const vw = video.videoWidth, vh = video.videoHeight, s = 320 / Math.max(vw, vh);
        small.width = Math.round(vw * s); small.height = Math.round(vh * s); sctx.drawImage(video, 0, 0, small.width, small.height);
        const g = CV.toGray(sctx.getImageData(0, 0, small.width, small.height).data, small.width, small.height);
        const r = await live.call('detect', { gray: g, w: small.width, h: small.height }, [g.buffer]);
        lastDet = r; lastSharp = r.sharp;
        const now = Date.now(); hist.push({ t: now, s: r.sharp }); while (hist.length && now - hist[0].t > 1200) hist.shift();
        tracker.update({ reliable: r.reliable, quad: r.quad && r.quad.map((p) => ({ x: p.x / small.width, y: p.y / small.height })) });
        $('#camHint').textContent = hint();
        if (S.auto && tracker.stable && r.sharp >= 18 && !r.issues.includes('corner_out_of_frame') && Date.now() > cooldown) capture();
      } catch { /* bỏ qua khung lỗi */ } finally { busy = false; }
    }
    function sharpNow() {
      const vw = video.videoWidth, vh = video.videoHeight, s = 320 / Math.max(vw, vh);
      small.width = Math.round(vw * s); small.height = Math.round(vh * s); sctx.drawImage(video, 0, 0, small.width, small.height);
      return CV.lapVar(CV.toGray(sctx.getImageData(0, 0, small.width, small.height).data, small.width, small.height), small.width, small.height);
    }
    async function grab() {
      if (ic) { try { return await Promise.race([ic.takePhoto(), sleep(2500).then(() => { throw new Error('timeout'); })]); } catch { /* dùng khung video */ } }
      // Chờ khung nét nhất (≤ 0,7 s) để tránh ảnh nhoè do tay bấm
      const best = hist.reduce((m, x) => Math.max(m, x.s), 0), t0 = Date.now();
      while (best && Date.now() - t0 < 700 && sharpNow() < best * 0.85) await sleep(50);
      const c = document.createElement('canvas'); c.width = video.videoWidth; c.height = video.videoHeight;
      c.getContext('2d').drawImage(video, 0, 0);
      const b = await toBlob(c, 'image/jpeg', 0.95); c.width = c.height = 0; return b;
    }
    async function capture() {
      if (capturing || !stream) return;
      capturing = true; $('#shutter').classList.add('busy');
      const fl = $('#camFlash'); fl.classList.add('on'); setTimeout(() => fl.classList.remove('on'), 80);
      if (navigator.vibrate) navigator.vibrate(25);
      try {
        const blob = await grab();
        $('#camBusy').classList.remove('hidden');
        const page = await addPage(curDoc, blob);
        batch.push(page);
        if (mode === 'single') { stop(); Flow.start([page], true); return; }
        updBottom(); toast(`Đã chụp ${batch.length} trang`, 1200);
      } catch (e) { toast('Lỗi khi chụp: ' + e.message, 4000); }
      finally { $('#camBusy').classList.add('hidden'); capturing = false; $('#shutter').classList.remove('busy'); tracker.reset(); cooldown = Date.now() + 1800; }
    }
    function updBottom() {
      $('#camCount').textContent = batch.length;
      const th = $('#camThumb');
      if (batch.length) { th.src = thumbURL(batch[batch.length - 1]); th.style.visibility = 'visible'; } else { th.removeAttribute('src'); th.style.visibility = 'hidden'; }
      $('#camDone').disabled = !batch.length;
    }
    $('#shutter').onclick = () => capture();
    $('#camClose').onclick = () => history.back();
    $('#camDone').onclick = () => { if (batch.length) { stop(); Flow.start(batch.slice(), true); } };
    $('#camAuto').onclick = () => { S.auto = !S.auto; saveS(); $('#camAuto').classList.toggle('off', !S.auto); toast(S.auto ? 'Bật tự chụp' : 'Tắt tự chụp', 1200); };
    $('#camGrid').onclick = () => { S.grid = !S.grid; saveS(); };
    $('#camTorch').onclick = async () => { try { torch = !torch; await track.applyConstraints({ advanced: [{ torch }] }); } catch { toast('Máy không hỗ trợ đèn'); } };
    $$('.cam-modes button').forEach((b) => b.onclick = () => { mode = b.dataset.m; $$('.cam-modes button').forEach((x) => x.classList.toggle('on', x === b)); });
    $('#camImport').onchange = async (e) => {
      const f = [...e.target.files]; e.target.value = ''; if (!f.length) return;
      const pages = await importFiles(f); if (!pages.length) return;
      stop(); Flow.start(batch.concat(pages), true);
    };
    $('#camView').addEventListener('click', async (e) => {
      if (!track) return;
      const r = rect(), b = $('#camView').getBoundingClientRect(), x = (e.clientX - b.left - r.x) / r.w, y = (e.clientY - b.top - r.y) / r.h;
      if (x < 0 || y < 0 || x > 1 || y > 1) return;
      const v = $('#camView'); v.style.setProperty('--fx', `${e.clientX - b.left}px`); v.style.setProperty('--fy', `${e.clientY - b.top}px`);
      v.classList.add('focus'); setTimeout(() => v.classList.remove('focus'), 800);
      try { await track.applyConstraints({ advanced: [{ pointsOfInterest: [{ x, y }], focusMode: 'single-shot' }] }); setTimeout(() => track && track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(() => { }), 1200); } catch { /* không hỗ trợ */ }
    });
    document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); else if (stack[stack.length - 1] === 'camera') start(); });
    return { start, stop, reset };
  })();
  onShow.camera = () => Cam.start();
  onLeave.camera = () => Cam.stop();

  // ------------------------------------------------------------ LUỒNG: Cắt → Lọc cho từng trang
  const Flow = (() => {
    let queue = [], i = 0, fromCamera = false;
    function start(pages, cam) { queue = pages; i = 0; fromCamera = !!cam; Crop.open(queue[0], label()); replaceOrShow('crop'); }
    function replaceOrShow(id) { if (stack[stack.length - 1] === 'camera' || stack[stack.length - 1] === 'filter' || stack[stack.length - 1] === 'crop') replace(id); else show(id); }
    const label = () => queue.length > 1 ? `${i + 1}/${queue.length}` : '';
    function toFilter() { Filter.open(queue[i], label()); replace('filter'); }
    async function next() {
      i++;
      if (i < queue.length) { Crop.open(queue[i], label()); replace('crop'); return; }
      queue = []; goDoc();
    }
    function single(page, where) { queue = [page]; i = 0; fromCamera = false; if (where === 'filter') { Filter.open(page, ''); show('filter'); } else { Crop.open(page, ''); show('crop'); } }
    async function drop(page) {
      await DB.del('pages', page.id);
      queue.splice(i, 1);
      if (i < queue.length) { Crop.open(queue[i], label()); replace('crop'); return; }
      if (fromCamera && !(await DB.pagesOf(curDoc.id)).length) { replace('camera'); return; }
      queue = []; goDoc();
    }
    return { start, toFilter, next, single, drop };
  })();

  // ------------------------------------------------------------ CẮT
  const Crop = (() => {
    const c = $('#cropCanvas'), lp = $('#loupe');
    let page = null, view = null, img = null, q = null, drag = -1, geo = null, rot = 0, last = null;
    async function open(p, lbl) {
      page = p; view = null; img = null; drag = -1;
      $('#cropCount').textContent = lbl || '';
      q = (p.edit.corners || full()).map((x) => ({ x: x.x, y: x.y }));
      rot = p.edit.rotation || 0;
      tools();
      const d = await decode(p, VIEW); view = d;
      img = toCanvas(d.rgba, d.w, d.h); d.rgba = null;
      if (page === p) draw();
      if (p.auto && !p.auto.sure) toast(p.auto.corners ? 'Góc giấy có thể bị ra ngoài khung – kéo chỉnh lại 4 góc' : 'Không thấy rõ tờ giấy – kéo 4 góc vào mép giấy', 3500);
    }
    const full = () => [{ x: 0, y: 0 }, { x: page.w, y: 0 }, { x: page.w, y: page.h }, { x: 0, y: page.h }];
    function tools() {
      const isFull = JSON.stringify(q) === JSON.stringify(full());
      $('#cropAll').classList.toggle('on', isFull);
      $('#cropAuto').classList.toggle('on', !!page.auto && JSON.stringify(q) === JSON.stringify(page.auto.corners));
      $('#cropCurve').classList.toggle('on', !!page.edit.dewarp);
    }
    function handles() {
      const h = q.map((p) => ({ x: p.x, y: p.y }));
      for (let k = 0; k < 4; k++) { const a = q[k], b = q[(k + 1) % 4]; h.push({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, edge: k }); }
      return h;
    }
    function draw() {
      if (!img) return;
      const dpr = Math.min(2, window.devicePixelRatio || 1), W = c.clientWidth, H = c.clientHeight;
      if (c.width !== Math.round(W * dpr) || c.height !== Math.round(H * dpr)) { c.width = Math.round(W * dpr); c.height = Math.round(H * dpr); }
      const pad = 28, s = Math.min((W - 2 * pad) / page.w, (H - 2 * pad) / page.h);
      geo = { s, ox: (W - page.w * s) / 2, oy: (H - page.h * s) / 2 };
      const ctx = c.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
      ctx.drawImage(img, geo.ox, geo.oy, page.w * s, page.h * s);
      const sp = q.map((p) => [geo.ox + p.x * s, geo.oy + p.y * s]);
      ctx.fillStyle = 'rgba(0,0,0,.5)'; ctx.beginPath(); ctx.rect(0, 0, W, H);
      ctx.moveTo(sp[0][0], sp[0][1]); for (let k = 3; k >= 0; k--) ctx.lineTo(sp[k][0], sp[k][1]); ctx.closePath(); ctx.fill('evenodd');
      ctx.strokeStyle = '#7c6bff'; ctx.lineWidth = 2.5; ctx.beginPath(); sp.forEach(([x, y], k) => k ? ctx.lineTo(x, y) : ctx.moveTo(x, y)); ctx.closePath(); ctx.stroke();
      handles().forEach((h, k) => {
        const x = geo.ox + h.x * s, y = geo.oy + h.y * s;
        ctx.beginPath();
        if (k < 4) ctx.arc(x, y, 12, 0, 7); else ctx.roundRect ? ctx.roundRect(x - 10, y - 10, 20, 20, 6) : ctx.rect(x - 10, y - 10, 20, 20);
        ctx.fillStyle = drag === k ? '#7c6bff' : 'rgba(255,255,255,.95)'; ctx.fill(); ctx.lineWidth = 3; ctx.strokeStyle = '#6C4DFF'; ctx.stroke();
      });
    }
    function loupe(pt, sx) {
      lp.classList.remove('hidden'); lp.style.left = sx < c.clientWidth / 2 ? `${c.clientWidth - 132}px` : '12px';
      lp.width = lp.height = 240; const ctx = lp.getContext('2d'), ps = img.width / page.w, src = 44;
      ctx.fillStyle = '#000'; ctx.fillRect(0, 0, 240, 240);
      ctx.drawImage(img, pt.x * ps - src / 2, pt.y * ps - src / 2, src, src, 0, 0, 240, 240);
      ctx.strokeStyle = '#ff4d6d'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(96, 120); ctx.lineTo(144, 120); ctx.moveTo(120, 96); ctx.lineTo(120, 144); ctx.stroke();
    }
    const toImg = (e) => { const r = c.getBoundingClientRect(); return { x: Math.max(0, Math.min(page.w, (e.clientX - r.left - geo.ox) / geo.s)), y: Math.max(0, Math.min(page.h, (e.clientY - r.top - geo.oy) / geo.s)), sx: e.clientX - r.left }; };
    c.addEventListener('pointerdown', (e) => {
      if (!geo) return;
      const p = toImg(e); let best = -1, bd = 40 / geo.s;
      handles().forEach((h, k) => { const d = Math.hypot(h.x - p.x, h.y - p.y) * (k < 4 ? 0.85 : 1); if (d < bd) { bd = d; best = k; } });
      if (best < 0) return;
      drag = best; last = p; c.setPointerCapture(e.pointerId); loupe(best < 4 ? q[best] : p, p.sx); draw();
    });
    c.addEventListener('pointermove', (e) => {
      if (drag < 0) return;
      const p = toImg(e);
      if (drag < 4) { q[drag] = { x: p.x, y: p.y }; loupe(q[drag], p.sx); }
      else {
        // kéo cạnh: dịch 2 góc theo pháp tuyến của cạnh
        const k = drag - 4, a = q[k], b = q[(k + 1) % 4], ex = b.x - a.x, ey = b.y - a.y, L = Math.hypot(ex, ey) || 1;
        const nx = -ey / L, ny = ex / L, d = (p.x - last.x) * nx + (p.y - last.y) * ny;
        for (const j of [k, (k + 1) % 4]) q[j] = { x: Math.max(0, Math.min(page.w, q[j].x + nx * d)), y: Math.max(0, Math.min(page.h, q[j].y + ny * d)) };
        loupe(p, p.sx);
      }
      last = p; draw();
    });
    const end = () => { if (drag < 0) return; drag = -1; lp.classList.add('hidden'); draw(); tools(); };
    c.addEventListener('pointerup', end); c.addEventListener('pointercancel', end);
    window.addEventListener('resize', () => { if (stack[stack.length - 1] === 'crop') draw(); });

    function valid() { const nq = CV.quadOrder(q); return CV.isConvex(nq) && CV.quadArea(nq) > 0.02 * page.w * page.h ? nq : null; }
    async function save() {
      const nq = valid(); if (!nq) { toast('Khung cắt không hợp lệ (bị xoắn hoặc quá nhỏ)'); return false; }
      const same = JSON.stringify(nq) === JSON.stringify(page.edit.corners);
      if (!same) { page.edit.corners = nq; if (!page.auto || JSON.stringify(nq) !== JSON.stringify(page.auto.corners)) page.edit.dewarp = null; else page.edit.dewarp = page.auto.dewarp; }
      page.edit.rotation = rot; page.dirty = true; await DB.put('pages', page); return true;
    }
    $('#cropAuto').onclick = () => { if (!page.auto || !page.auto.corners) return toast('Không tự nhận được tờ giấy trong ảnh này'); q = page.auto.corners.map((x) => ({ ...x })); page.edit.dewarp = page.auto.dewarp; draw(); tools(); };
    $('#cropAll').onclick = () => { q = full(); page.edit.dewarp = null; draw(); tools(); };
    $('#cropRot').onclick = () => { rot = (rot + 1) % 4; toast(`Xoay ${rot * 90}° – áp dụng ở bước sau`, 1200); };
    $('#cropCurve').onclick = async () => {
      if (page.edit.dewarp) { page.edit.dewarp = null; tools(); return toast('Đã tắt nắn cong', 1200); }
      const nq = valid(); if (!nq) return toast('Hãy đặt 4 góc trước');
      const sp = progress('Đang phân tích giấy cong'); sp.set('Xử lý trên máy…', 0.5);
      try {
        const d = await decode(page, WORK);
        const r = await heavy.call('dewarp', { rgba: d.rgba, w: d.w, h: d.h, quad: scaleQ(nq, d.scale) }, [d.rgba.buffer]);
        sp.close();
        if (!r.dewarp) return toast('Giấy phẳng – không cần nắn cong');
        q = scaleQ(r.corners, 1 / d.scale); page.edit.corners = CV.quadOrder(q); page.edit.dewarp = scaleModel(r.dewarp, 1 / d.scale);
        draw(); tools(); toast(r.kind === 'curl' ? 'Đã nắn mép quăn' : 'Đã nắn theo mép cong');
      } catch (e) { sp.close(); toast('Lỗi: ' + e.message); }
    };
    $('#cropRetake').onclick = async () => { if (await ask('Bỏ ảnh này?', 'Ảnh sẽ bị xoá.', 'Bỏ ảnh', 'Giữ', true)) Flow.drop(page); };
    $('#cropNext').onclick = async () => { if (await save()) Flow.toFilter(); };
    $('#cropBack').onclick = () => history.back();
    return { open, draw };
  })();
  onShow.crop = () => setTimeout(() => Crop.draw(), 30);

  // ------------------------------------------------------------ BỘ LỌC
  const Filter = (() => {
    const cv = $('#filCanvas');
    let page = null, base = null, smallB = null, orig = null, proc = document.createElement('canvas'), seq = 0, holding = false, liveBusy = false, livePend = false, t = null;
    async function open(p, lbl) {
      page = p; $('#filTitle').textContent = lbl ? `Bộ lọc ${lbl}` : 'Bộ lọc';
      $('#adjPanel').classList.add('hidden'); $('#filSpin').classList.remove('hidden');
      const d = await decode(p, VIEW); base = d;
      const sd = CV.downRGBA(d.rgba, d.w, d.h, 520); smallB = { rgba: sd.rgba, w: sd.w, h: sd.h, scale: d.scale * sd.s };
      orig = null; syncSliders(); strip(); render();
    }
    function syncSliders() {
      for (const [id, k] of [['#adjB', 'brightness'], ['#adjC', 'contrast'], ['#adjS', 'sharpness'], ['#adjR', 'fineRotation']]) { const el = $(id); el.value = page.edit[k] || 0; el.nextElementSibling.textContent = (+el.value).toFixed(k === 'fineRotation' ? 1 : 2); }
      $('#filShadow').classList.toggle('on', !!page.edit.deshadow);
    }
    function render(liveMode) {
      if (!base) return;
      const src = liveMode ? smallB : base;
      if (liveMode) { if (liveBusy) { livePend = true; return; } liveBusy = true; }
      const my = ++seq; if (!liveMode) $('#filSpin').classList.remove('hidden');
      const r = new Uint8ClampedArray(src.rgba);
      heavy.call('render', { rgba: r, w: src.w, h: src.h, params: paramsAt(page.edit, src.scale), scale: 1, bicubic: false }, [r.buffer]).then((o) => {
        if (!liveMode && my !== seq) return;
        toCanvas(o.rgba, o.w, o.h, proc); paint(); if (!liveMode) $('#filSpin').classList.add('hidden');
      }).catch((e) => { $('#filSpin').classList.add('hidden'); toast('Lỗi xử lý: ' + e.message); })
        .finally(() => { if (liveMode) { liveBusy = false; if (livePend) { livePend = false; render(true); } } });
    }
    function paint() {
      const src = holding ? (orig || (orig = toCanvas(base.rgba, base.w, base.h))) : proc;
      cv.width = src.width; cv.height = src.height; cv.getContext('2d').drawImage(src, 0, 0);
    }
    async function strip() {
      const el = $('#filStrip'); el.innerHTML = '';
      const tiny = CV.downRGBA(smallB.rgba, smallB.w, smallB.h, 200), sc = smallB.scale * tiny.s;
      for (const f of FILTERS) {
        const b = document.createElement('button'); b.className = 'fil' + (page.edit.filter === f.id ? ' on' : '');
        const cc = document.createElement('canvas'); b.appendChild(cc); b.append(f.label);
        b.onclick = () => { Object.assign(page.edit, f.p, { filter: f.id }); page.dirty = true; $$('.fil').forEach((x) => x.classList.toggle('on', x === b)); syncSliders(); render(); };
        el.appendChild(b);
        const r = new Uint8ClampedArray(tiny.rgba);
        heavy.call('render', { rgba: r, w: tiny.w, h: tiny.h, params: paramsAt(Object.assign({}, page.edit, f.p), sc), scale: 1, bicubic: false }, [r.buffer])
          .then((o) => toCanvas(o.rgba, o.w, o.h, cc)).catch(() => { });
      }
    }
    function bindSlider(id, k) {
      const el = $(id);
      el.oninput = () => { page.edit[k] = parseFloat(el.value); el.nextElementSibling.textContent = (+el.value).toFixed(k === 'fineRotation' ? 1 : 2); page.dirty = true; render(true); clearTimeout(t); t = setTimeout(() => render(false), 400); };
    }
    bindSlider('#adjB', 'brightness'); bindSlider('#adjC', 'contrast'); bindSlider('#adjS', 'sharpness'); bindSlider('#adjR', 'fineRotation');
    $('#filShadow').onclick = () => {
      page.edit.deshadow = !page.edit.deshadow; page.dirty = true; syncSliders(); render(); strip();
      toast(page.edit.deshadow ? 'Đã bật xoá bóng đèn' : 'Đã tắt xoá bóng', 1200);
    };
    $('#filAdj').onclick = () => $('#adjPanel').classList.toggle('hidden');
    $('#filRot').onclick = () => { page.edit.rotation = ((page.edit.rotation || 0) + 1) % 4; page.dirty = true; render(); strip(); };
    const hold = $('#filHold');
    hold.onpointerdown = () => { holding = true; paint(); };
    hold.onpointerup = hold.onpointerleave = hold.onpointercancel = () => { if (holding) { holding = false; paint(); } };
    $('#filBack').onclick = () => { Crop.open(page, $('#cropCount').textContent); replace('crop'); };
    $('#filDone').onclick = async () => {
      const sp = progress('Đang hoàn tất trang'); sp.set('Dựng ảnh chất lượng cao (A4 300 DPI)…', 0.5);
      try { await DB.put('pages', page); await finalize(page); sp.close(); base = smallB = orig = null; Flow.next(); }
      catch (e) { sp.close(); toast('Lỗi: ' + e.message, 4000); }
    };
    return { open };
  })();

  // ------------------------------------------------------------ TÀI LIỆU
  onShow.doc = async () => {
    if (!curDoc) return replace('home');
    $('#docName').textContent = curDoc.name;
    const pages = await DB.pagesOf(curDoc.id), grid = $('#pageGrid'); grid.innerHTML = '';
    if (!pages.length) grid.innerHTML = '<p class="muted center" style="grid-column:1/-1">Chưa có trang nào – bấm “Thêm trang”.</p>';
    pages.forEach((p, i) => {
      const el = document.createElement('button'); el.className = 'pg';
      const warn = p.auto && !p.auto.sure && JSON.stringify(p.edit.corners) === JSON.stringify(p.auto.corners) ? '<span class="warn">⚠️</span>' : '';
      el.innerHTML = `<img src="${thumbURL(p)}" alt="">${warn}<span>${i + 1}</span>`;
      el.onclick = async () => {
        const k = await menu(`Trang ${i + 1}`, [['crop', '✂️', 'Cắt lại'], ['filter', '🎨', 'Bộ lọc / Điều chỉnh'], ['rot', '⟳', 'Xoay 90°'],
          ['left', '←', 'Chuyển lên trước'], ['right', '→', 'Chuyển ra sau'], ['del', '🗑', 'Xoá trang', true]]);
        if (!k) return;
        if (k === 'crop' || k === 'filter') return Flow.single(p, k);
        if (k === 'rot') { p.edit.rotation = ((p.edit.rotation || 0) + 1) % 4; const sp = progress('Đang xoay'); sp.set('…', 0.5); await finalize(p); sp.close(); }
        if (k === 'del') { if (!(await ask(`Xoá trang ${i + 1}?`, 'Trang sẽ bị xoá khỏi máy.', 'Xoá', 'Huỷ', true))) return; await DB.del('pages', p.id); }
        if (k === 'left' || k === 'right') { const j = k === 'left' ? i - 1 : i + 1; if (j < 0 || j >= pages.length) return; [pages[i], pages[j]] = [pages[j], pages[i]]; }
        const order = (k === 'left' || k === 'right') ? pages : await DB.pagesOf(curDoc.id);
        for (let n = 0; n < order.length; n++) if (order[n].idx !== n) { order[n].idx = n; await DB.put('pages', order[n]); }
        await touch(curDoc); onShow.doc();
      };
      grid.appendChild(el);
    });
  };
  $('#docBack').onclick = () => { while (stack.length > 1) stack.pop(); $$('.screen').forEach((s) => s.classList.toggle('active', s.id === 'home')); onShow.home(); };
  $('#docRename').onclick = async () => { const n = await promptText('Đổi tên tài liệu', curDoc.name); if (n) { curDoc.name = n; await touch(curDoc); onShow.doc(); } };
  $('#docAdd').onclick = () => { Cam.reset(); show('camera'); };
  $('#docImport').onchange = async (e) => { const f = [...e.target.files]; e.target.value = ''; if (!f.length) return; const pages = await importFiles(f); if (pages.length) Flow.start(pages); };
  $('#docPdf').onclick = () => Export.pdf(false);
  $('#docShare').onclick = async () => {
    const k = await menu('Chia sẻ', [['pdf', '📄', 'PDF'], ['jpg', '🖼️', 'Ảnh JPG (từng trang)'], ['orig', '📷', 'Ảnh gốc chưa xử lý']]);
    if (k === 'pdf') Export.pdf(true); else if (k) Export.images(k);
  };

  // ------------------------------------------------------------ XUẤT / CHIA SẺ
  const Export = (() => {
    async function ensure(pages, pg) {
      for (let i = 0; i < pages.length; i++) {
        if (!pages[i].outBytes || pages[i].dirty) { pg.set(`Hoàn tất trang ${i + 1}/${pages.length}…`, i / pages.length); await finalize(pages[i]); }
      }
    }
    async function deliver(files, share) {
      const canShare = navigator.canShare && navigator.canShare({ files });
      // iPhone: mở bảng chia sẻ (có "Lưu vào Tệp") vì tải file trực tiếp không ổn định
      if (canShare && (share || isIOS)) {
        try { await navigator.share({ files, title: files[0].name }); return; } catch (e) { if (e.name === 'AbortError') return; }
      }
      for (const f of files) {
        const a = document.createElement('a'); a.href = URL.createObjectURL(f); a.download = f.name;
        document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 60000); await sleep(300);
      }
      toast(share ? 'Trình duyệt chưa hỗ trợ chia sẻ file – đã lưu về máy' : `Đã lưu ${files.length > 1 ? files.length + ' file' : files[0].name}`, 3500);
    }
    async function pdf(share) {
      const pages = await DB.pagesOf(curDoc.id); if (!pages.length) return toast('Tài liệu chưa có trang');
      const pg = progress('Đang tạo PDF');
      try {
        await ensure(pages, pg); pg.set('Ghép PDF…', 0.95);
        const blob = await PDFW.build(pages.map((p) => ({ w: p.outW, h: p.outH, jpeg: new Uint8Array(p.outBytes) })), { size: S.page === 'auto' ? null : S.page, title: curDoc.name });
        pg.close();
        await deliver([new File([blob], `${sanitize(curDoc.name)}.pdf`, { type: 'application/pdf' })], share);
        await touch(curDoc);
      } catch (e) { pg.close(); toast('Lỗi tạo PDF: ' + e.message, 4000); }
    }
    async function images(kind) {
      const pages = await DB.pagesOf(curDoc.id), base = sanitize(curDoc.name), pg = progress('Đang chuẩn bị ảnh');
      try {
        if (kind === 'jpg') await ensure(pages, pg);
        pg.close();
        const files = pages.map((p, i) => {
          const suf = pages.length > 1 ? `_${two(i + 1)}` : '';
          if (kind === 'jpg') return new File([p.outBytes], `${base}${suf}.jpg`, { type: 'image/jpeg' });
          const b = pageBlob(p); return new File([b], `${base}${suf}_goc.${(b.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg')}`, { type: b.type || 'image/jpeg' });
        });
        await deliver(files, true);
      } catch (e) { pg.close(); toast('Lỗi: ' + e.message, 4000); }
    }
    return { pdf, images };
  })();

  // ------------------------------------------------------------ CÀI ĐẶT
  onShow.settings = () => {
    $('#setAuto').checked = S.auto; $('#setGrid').checked = S.grid;
    $('#setFilter').innerHTML = FILTERS.map((f) => `<button data-v="${f.id}" class="${f.id === S.filter ? 'on' : ''}">${f.label}</button>`).join('');
    $$('#setFilter button').forEach((b) => b.onclick = () => { S.filter = b.dataset.v; saveS(); onShow.settings(); });
    $('#setPage').innerHTML = PAGE_SIZES.map(([v, l]) => `<button data-v="${v}" class="${v === S.page ? 'on' : ''}">${l}</button>`).join('');
    $$('#setPage button').forEach((b) => b.onclick = () => { S.page = b.dataset.v; saveS(); onShow.settings(); });
  };
  $('#setAuto').onchange = (e) => { S.auto = e.target.checked; saveS(); };
  $('#setGrid').onchange = (e) => { S.grid = e.target.checked; saveS(); };

  try { navigator.storage && navigator.storage.persist && navigator.storage.persist(); } catch { /* bỏ qua */ }
  if ('serviceWorker' in navigator && location.protocol !== 'file:') navigator.serviceWorker.register('sw.js').catch(() => { });
  onShow.home();
})();
