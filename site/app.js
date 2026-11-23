/* APP scan PDF – bản web (PWA). App làm bởi Đào Duy Thanh, © since 2026.
 * Toàn bộ xử lý chạy trên máy (Web Worker). Không gửi ảnh lên máy chủ. */
(() => {
  'use strict';
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => [...document.querySelectorAll(s)];
  const MAX_PIXELS = 16e6; // giới hạn canvas an toàn trên iPhone
  const MODES = [['document', 'Scan rõ chữ'], ['original', 'Màu gốc'], ['gray', 'Scan xám'], ['bw', 'Trắng đen']];
  const PAPERS = [['auto', 'Tự động (A4)'], ['a4', 'A4/A5'], ['letter', 'Letter'], ['legal', 'Legal'], ['free', 'Không ép']];

  // ------------------------------------------------------------ tiện ích UI
  let toastTimer;
  function toast(msg, ms = 2600) {
    const t = $('#toast'); t.textContent = msg; t.classList.add('show');
    clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), ms);
  }
  function sheet(html) {
    $('#sheet').innerHTML = html; $('#modal').classList.remove('hidden');
    return $('#sheet');
  }
  const closeSheet = () => $('#modal').classList.add('hidden');
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  function ask(title, msg, ok = 'Đồng ý', cancel = 'Huỷ', danger = false) {
    return new Promise((res) => {
      const s = sheet(`<h3>${esc(title)}</h3><div class="muted">${msg}</div><div class="btns">
        ${cancel ? `<button class="btn outline" data-r="0">${esc(cancel)}</button>` : ''}
        <button class="btn ${danger ? 'danger' : ''}" data-r="1">${esc(ok)}</button></div>`);
      s.querySelectorAll('[data-r]').forEach((b) => b.onclick = () => { closeSheet(); res(b.dataset.r === '1'); });
    });
  }
  function promptText(title, value) {
    return new Promise((res) => {
      const s = sheet(`<h3>${esc(title)}</h3><input class="input" id="pIn" value="${esc(value || '')}">
        <div class="btns"><button class="btn outline" data-r="0">Huỷ</button><button class="btn" data-r="1">Lưu</button></div>`);
      const inp = s.querySelector('#pIn'); setTimeout(() => { inp.focus(); inp.select(); }, 50);
      s.querySelectorAll('[data-r]').forEach((b) => b.onclick = () => { closeSheet(); res(b.dataset.r === '1' && inp.value.trim() ? inp.value.trim() : null); });
    });
  }
  function progress(title) {
    const s = sheet(`<h3>${esc(title)}</h3><div class="muted" id="pgTxt">Đang chuẩn bị…</div><div class="progress"><i id="pgBar"></i></div>`);
    return {
      set(txt, f) { s.querySelector('#pgTxt').textContent = txt; s.querySelector('#pgBar').style.width = `${Math.round(f * 100)}%`; },
      close: closeSheet,
    };
  }
  const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2));
  const two = (n) => String(n).padStart(2, '0');
  const defaultName = (d = new Date()) => `Scan ${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}h${two(d.getMinutes())}`;
  const sanitize = (s) => (s || 'TaiLieu').replace(/[\\/:*?"<>|\x00-\x1F]/g, '_').replace(/\s+/g, ' ').trim().slice(0, 120) || 'TaiLieu';
  const fmtDate = (t) => { const d = new Date(t); return `${two(d.getDate())}/${two(d.getMonth() + 1)}/${d.getFullYear()} ${two(d.getHours())}:${two(d.getMinutes())}`; };
  const fmtBytes = (b) => b < 1048576 ? `${(b / 1024).toFixed(0)} KB` : `${(b / 1048576).toFixed(1)} MB`;

  // ------------------------------------------------------------ cài đặt
  const SETTINGS_KEY = 'appscanpdf.settings';
  const S = Object.assign({ auto: true, grid: true, mode: 'document' }, (() => { try { return JSON.parse(localStorage.getItem(SETTINGS_KEY)) || {}; } catch { return {}; } })());
  const saveSettings = () => { try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(S)); } catch { /* chế độ riêng tư */ } };

  // ------------------------------------------------------------ IndexedDB
  const DB = (() => {
    let dbp;
    const open = () => dbp || (dbp = new Promise((res, rej) => {
      const r = indexedDB.open('appscanpdf', 1);
      r.onupgradeneeded = () => {
        const db = r.result;
        db.createObjectStore('docs', { keyPath: 'id' });
        db.createObjectStore('pages', { keyPath: 'id' }).createIndex('docId', 'docId');
      };
      r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
    }));
    const tx = async (store, mode, fn) => {
      const db = await open();
      return new Promise((res, rej) => {
        const t = db.transaction(store, mode), st = t.objectStore(store);
        let out; const r = fn(st); if (r) r.onsuccess = () => { out = r.result; };
        t.oncomplete = () => res(out); t.onerror = () => rej(t.error); t.onabort = () => rej(t.error || new Error('Bộ nhớ đầy hoặc bị từ chối'));
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

  // ------------------------------------------------------------ worker RPC
  function makeWorker() {
    const w = new Worker('worker.js'); let seq = 0; const pend = new Map();
    w.onmessage = (e) => { const p = pend.get(e.data.id); if (!p) return; pend.delete(e.data.id); e.data.error ? p.rej(new Error(e.data.error)) : p.res(e.data.result); };
    w.onerror = (e) => { for (const p of pend.values()) p.rej(new Error(e.message || 'Lỗi worker')); pend.clear(); };
    return { call(op, data = {}, transfer = []) { const id = ++seq; return new Promise((res, rej) => { pend.set(id, { res, rej }); w.postMessage(Object.assign({ id, op }, data), transfer); }); } };
  }
  const heavy = makeWorker(); const live = makeWorker();

  // ------------------------------------------------------------ ảnh
  async function decode(blob, maxSide = Infinity) {
    let bmp;
    try { bmp = await createImageBitmap(blob, { imageOrientation: 'from-image' }); } catch { bmp = await createImageBitmap(blob); }
    const fullW = bmp.width, fullH = bmp.height;
    let s = Math.min(1, maxSide / Math.max(fullW, fullH), Math.sqrt(MAX_PIXELS / (fullW * fullH)));
    const w = Math.max(1, Math.round(fullW * s)), h = Math.max(1, Math.round(fullH * s));
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const ctx = c.getContext('2d', { willReadFrequently: true });
    ctx.imageSmoothingQuality = 'high'; ctx.drawImage(bmp, 0, 0, w, h); bmp.close && bmp.close();
    const rgba = ctx.getImageData(0, 0, w, h).data;
    return { rgba, w, h, fullW, fullH, scale: w / fullW };
  }
  function toCanvas(rgba, w, h, canvas) {
    const c = canvas || document.createElement('canvas'); c.width = w; c.height = h;
    c.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(rgba.buffer || rgba, rgba.byteOffset || 0, w * h * 4), w, h), 0, 0);
    return c;
  }
  const toBlob = (canvas, type, q) => new Promise((res) => canvas.toBlob(res, type, q));
  const copy = (u8) => new Uint8ClampedArray(u8); // bản sao để chuyển sang worker

  // ------------------------------------------------------------ điều hướng
  const stack = ['home'];
  async function show(id, push = true) {
    const prevScreen = (document.querySelector('.screen.active') || {}).id;
    if (prevScreen === 'editor' && id !== 'editor' && window.__editorClose) await window.__editorClose();
    $$('.screen').forEach((s) => s.classList.toggle('active', s.id === id));
    if (push) { stack.push(id); history.pushState({ s: id }, ''); }
    if (id !== 'camera') Camera.stop();
    (onShow[id] || (() => { }))();
  }
  function back() {
    if (!$('#modal').classList.contains('hidden')) { closeSheet(); return; }
    if (stack.length > 1) { stack.pop(); show(stack[stack.length - 1], false); }
  }
  window.addEventListener('popstate', () => { back(); if (stack.length === 1) history.pushState({ s: 'home' }, ''); });
  history.replaceState({ s: 'home' }, ''); history.pushState({ s: 'home' }, '');
  $$('[data-back]').forEach((b) => b.onclick = () => history.back());
  $$('[data-go]').forEach((b) => b.onclick = () => show(b.dataset.go));
  $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeSheet(); });
  const onShow = {};

  // ------------------------------------------------------------ dữ liệu tài liệu
  let curDoc = null;
  async function newDoc() {
    const d = { id: uid(), name: defaultName(), createdAt: Date.now(), updatedAt: Date.now(), status: 'draft' };
    await DB.put('docs', d); return d;
  }
  async function touch(doc) { doc.updatedAt = Date.now(); await DB.put('docs', doc); }
  const thumbURLs = new Map();
  function thumbURL(page) {
    const k = page.id + ':' + (page.thumbVer || 0);
    if (!thumbURLs.has(k) && page.thumb) thumbURLs.set(k, URL.createObjectURL(page.thumb));
    return thumbURLs.get(k) || '';
  }

  /** Thêm trang từ ảnh (giữ nguyên file gốc). Trả về {page, analysis}. */
  async function addPage(doc, blob) {
    const img = await decode(blob);
    const pages = await DB.pagesOf(doc.id);
    // Lưu ảnh gốc TRƯỚC – không mất trang nếu trình duyệt bị đóng giữa chừng.
    const page = { id: uid(), docId: doc.id, idx: pages.length, blob, w: img.fullW, h: img.fullH, edit: { mode: S.mode, paper: 'auto', rotation: 0 }, createdAt: Date.now() };
    await DB.put('pages', page);
    const r = await heavy.call('ingest', { rgba: img.rgba, w: img.w, h: img.h, mode: S.mode }, [img.rgba.buffer]);
    const sc = 1 / img.scale; // toạ độ về ảnh gốc đầy đủ
    const a = r.analysis;
    const scaleQ = (q) => q && q.map((p) => ({ x: p.x * sc, y: p.y * sc }));
    page.edit = Object.assign({}, r.params, { corners: scaleQ(a.corners), dewarp: a.dewarp ? scaleModel(a.dewarp, sc) : null });
    page.issues = a.issues.map((i) => i.code);
    page.kind = a.kind;
    page.thumb = await toBlob(toCanvas(r.thumb.rgba, r.thumb.w, r.thumb.h), 'image/jpeg', 0.82); page.thumbVer = 1;
    await DB.put('pages', page); await touch(doc);
    return { page, analysis: a };
  }
  /** Mô hình nắn cong tính trên ảnh đã giới hạn điểm ảnh → quy về ảnh gốc. */
  function scaleModel(m, s) {
    if (s === 1 || !m) return m;
    const j = JSON.parse(JSON.stringify(m));
    if (j.type === 'coons') j.quad = j.quad.map((p) => ({ x: p.x * s, y: p.y * s }));
    if (j.type === 'cyl') { j.f *= s; j.cx *= s; j.cy *= s; }
    return j;
  }
  async function refreshThumb(page) {
    const img = await decode(page.blob, 1400);
    const t = await heavy.call('thumb', { rgba: img.rgba, w: img.w, h: img.h, params: scaleParams(page.edit, img.scale) }, [img.rgba.buffer]);
    page.thumb = await toBlob(toCanvas(t.rgba, t.w, t.h), 'image/jpeg', 0.82); page.thumbVer = (page.thumbVer || 0) + 1;
    await DB.put('pages', page);
  }
  /** Tham số với toạ độ quy về ảnh đã thu nhỏ (worker nhận scale=1 trên ảnh nhỏ). */
  function scaleParams(e, s) {
    const p = Object.assign({}, e);
    if (p.corners) p.corners = p.corners.map((q) => ({ x: q.x * s, y: q.y * s }));
    if (p.dewarp) p.dewarp = scaleModel(p.dewarp, s);
    return p;
  }

  async function ingestFiles(doc, files) {
    const pg = progress(`Đang nhập ${files.length} ảnh`);
    const notes = [];
    for (let i = 0; i < files.length; i++) {
      pg.set(`Ảnh ${i + 1}/${files.length}: ${files[i].name}`, i / files.length);
      try {
        const { analysis } = await addPage(doc, files[i]);
        const bad = analysis.issues.filter((x) => x.sev >= 1);
        if (bad.length) notes.push(`${files[i].name}: ${bad[0].msg}`);
        if (!analysis.corners) notes.push(`${files[i].name}: cần chỉnh 4 góc bằng tay.`);
      } catch (e) {
        notes.push(`${files[i].name}: không đọc được ảnh (${e.message}).`);
      }
    }
    pg.close();
    if (notes.length) await ask('Lưu ý về ảnh đã nhập', notes.map(esc).join('<br><br>'), 'Đã hiểu', '');
  }

  // ------------------------------------------------------------ TRANG CHỦ
  onShow.home = async () => {
    const docs = (await DB.all('docs')).sort((a, b) => b.updatedAt - a.updatedAt);
    const list = $('#recent'); list.innerHTML = '';
    $('#recentTitle').classList.toggle('hidden', !docs.length);
    for (const d of docs.slice(0, 6)) {
      const pages = await DB.pagesOf(d.id);
      if (!pages.length) { await DB.del('docs', d.id); continue; }
      list.appendChild(docItem(d, pages));
    }
  };
  function docItem(d, pages) {
    const el = document.createElement('div'); el.className = 'doc-item';
    el.innerHTML = `<img src="${thumbURL(pages[0])}" alt=""><div class="info"><b class="ellipsis">${esc(d.name)}</b>
      <small>${pages.length} trang • ${fmtDate(d.updatedAt)}${d.status === 'draft' ? ' • nháp' : ''}</small></div><span style="font-size:22px;color:#aaa">›</span>`;
    el.onclick = () => { curDoc = d; show('doc'); };
    return el;
  }
  $('#btnScan').onclick = async () => { requestMotion(); curDoc = await newDoc(); show('camera'); };
  $('#fileImport').onchange = async (e) => {
    const files = [...e.target.files]; e.target.value = '';
    if (!files.length) return;
    curDoc = await newDoc(); await ingestFiles(curDoc, files); show('doc');
  };

  // ------------------------------------------------------------ CAMERA
  const Camera = (() => {
    let stream = null, track = null, imageCapture = null, running = false, busy = false, capturing = false;
    let tracker = CV.Tracker(8), lastDet = null, lastSharp = 0, cooldown = 0, torchOn = false, loopTimer = null;
    const video = $('#video'), overlay = $('#overlay'), small = document.createElement('canvas');
    const sctx = small.getContext('2d', { willReadFrequently: true });

    async function start() {
      $('#camHint').textContent = 'Đang mở camera…';
      updateBottom();
      $('#camAuto').classList.toggle('off', !S.auto); $('#camAuto').textContent = S.auto ? 'Tự động' : 'Thủ công';
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        $('#camHint').textContent = 'Trình duyệt không hỗ trợ camera. Hãy dùng nút 🖼️ để chọn ảnh.'; return;
      }
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          audio: false,
          video: { facingMode: { ideal: 'environment' }, width: { ideal: 4096 }, height: { ideal: 4096 } },
        });
      } catch (e) {
        $('#camHint').textContent = e.name === 'NotAllowedError'
          ? 'Chưa cấp quyền camera. Hãy cho phép camera trong cài đặt trình duyệt, hoặc dùng 🖼️ để chọn ảnh.'
          : 'Không mở được camera: ' + e.message;
        return;
      }
      track = stream.getVideoTracks()[0];
      video.srcObject = stream;
      try { await video.play(); } catch { /* iOS cần thao tác người dùng – đã có */ }
      try { if ('ImageCapture' in window) imageCapture = new ImageCapture(track); } catch { imageCapture = null; }
      const caps = track.getCapabilities ? track.getCapabilities() : {};
      $('#camTorch').hidden = !caps.torch;
      try { await track.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }); } catch { /* không hỗ trợ */ }
      running = true; tracker.reset(); loop();
    }
    function stop() {
      running = false; clearTimeout(loopTimer);
      if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; track = null; imageCapture = null; }
      video.srcObject = null;
    }
    function viewRect() {
      const cw = overlay.clientWidth, ch = overlay.clientHeight, vw = video.videoWidth || 1, vh = video.videoHeight || 1;
      const s = Math.min(cw / vw, ch / vh);
      return { x: (cw - vw * s) / 2, y: (ch - vh * s) / 2, w: vw * s, h: vh * s };
    }
    function draw() {
      const dpr = window.devicePixelRatio || 1;
      const cw = overlay.clientWidth, ch = overlay.clientHeight;
      if (overlay.width !== Math.round(cw * dpr)) { overlay.width = Math.round(cw * dpr); overlay.height = Math.round(ch * dpr); }
      const ctx = overlay.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, cw, ch);
      const r = viewRect();
      if (S.grid) {
        ctx.strokeStyle = 'rgba(255,255,255,.35)'; ctx.lineWidth = 1; ctx.beginPath();
        for (let i = 1; i < 3; i++) { ctx.moveTo(r.x + r.w * i / 3, r.y); ctx.lineTo(r.x + r.w * i / 3, r.y + r.h); ctx.moveTo(r.x, r.y + r.h * i / 3); ctx.lineTo(r.x + r.w, r.y + r.h * i / 3); }
        ctx.stroke();
        const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
        ctx.strokeStyle = 'rgba(255,255,255,.75)'; ctx.lineWidth = 1.5; ctx.beginPath();
        ctx.moveTo(cx - 12, cy); ctx.lineTo(cx + 12, cy); ctx.moveTo(cx, cy - 12); ctx.lineTo(cx, cy + 12); ctx.stroke();
        let fw = r.w * 0.82, fh = fw * 1.4142; if (fh > r.h * 0.9) { fh = r.h * 0.9; fw = fh / 1.4142; }
        const L = fw * 0.12, x0 = cx - fw / 2, y0 = cy - fh / 2;
        ctx.strokeStyle = 'rgba(255,255,255,.85)'; ctx.lineWidth = 3; ctx.beginPath();
        for (const [px, py, dx, dy] of [[x0, y0, 1, 1], [x0 + fw, y0, -1, 1], [x0 + fw, y0 + fh, -1, -1], [x0, y0 + fh, 1, -1]]) {
          ctx.moveTo(px + L * dx, py); ctx.lineTo(px, py); ctx.lineTo(px, py + L * dy);
        }
        ctx.stroke();
      }
      const q = tracker.quad;
      if (q) {
        const pr = tracker.progress, col = `rgb(${Math.round(255 - 150 * pr)},${Math.round(200 + 40 * pr)},${Math.round(60 + 110 * pr)})`;
        ctx.beginPath(); q.forEach((p, i) => { const X = r.x + p.x * r.w, Y = r.y + p.y * r.h; i ? ctx.lineTo(X, Y) : ctx.moveTo(X, Y); }); ctx.closePath();
        ctx.fillStyle = col.replace('rgb', 'rgba').replace(')', ',.2)'); ctx.fill();
        ctx.strokeStyle = col; ctx.lineWidth = 3; ctx.stroke();
        for (const p of q) { ctx.beginPath(); ctx.arc(r.x + p.x * r.w, r.y + p.y * r.h, 7, 0, 7); ctx.fillStyle = col; ctx.fill(); }
      }
    }
    function hint() {
      const d = lastDet;
      if (!d || !d.quad) return 'Đưa trọn tờ giấy vào khung, đặt trên nền tối hơn giấy';
      if (d.issues.includes('corner_out_of_frame')) return 'Lùi máy ra – có góc giấy nằm ngoài khung';
      if (d.issues.includes('too_small')) return 'Đưa máy lại gần tài liệu hơn';
      if (d.issues.includes('occluded')) return 'Tài liệu đang bị che – bỏ tay/vật cản ra';
      if (d.issues.includes('low_contrast')) return 'Giấy và nền khó phân biệt – đổi sang nền tối hơn';
      if (lastSharp < 18) return 'Giữ máy chắc tay để lấy nét…';
      if (!d.reliable) return 'Đang tìm 4 góc…';
      return S.auto ? 'Giữ yên – sẽ tự động chụp' : 'Đã thấy tài liệu – bấm nút để chụp';
    }
    async function loop() {
      if (!running) return;
      loopTimer = setTimeout(loop, 140);
      draw();
      if (busy || capturing || !video.videoWidth) return;
      busy = true;
      try {
        const vw = video.videoWidth, vh = video.videoHeight, s = 320 / Math.max(vw, vh);
        small.width = Math.round(vw * s); small.height = Math.round(vh * s);
        sctx.drawImage(video, 0, 0, small.width, small.height);
        const g = CV.toGray(sctx.getImageData(0, 0, small.width, small.height).data, small.width, small.height);
        const r = await live.call('detect', { gray: g, w: small.width, h: small.height }, [g.buffer]);
        lastDet = r; lastSharp = r.sharp;
        tracker.update({ reliable: r.reliable, quad: r.quad && r.quad.map((p) => ({ x: p.x / small.width, y: p.y / small.height })) });
        $('#camHint').textContent = hint();
        if (S.auto && tracker.stable && r.sharp >= 18 && !r.issues.includes('corner_out_of_frame') && !r.issues.includes('occluded') && Date.now() > cooldown) capture();
      } catch { /* bỏ qua khung lỗi */ } finally { busy = false; }
    }
    async function grabFrame() {
      if (imageCapture) {
        try { return await imageCapture.takePhoto(); } catch { /* không hỗ trợ → lấy khung video */ }
      }
      const c = document.createElement('canvas'); c.width = video.videoWidth; c.height = video.videoHeight;
      c.getContext('2d').drawImage(video, 0, 0); return toBlob(c, 'image/jpeg', 0.95);
    }
    async function capture() {
      if (capturing || !stream) return;
      capturing = true; $('#shutter').classList.add('busy');
      const fl = $('#camFlash'); fl.classList.add('on'); setTimeout(() => fl.classList.remove('on'), 60);
      if (navigator.vibrate) navigator.vibrate(30);
      try {
        const blob = await grabFrame();
        $('#camHint').textContent = 'Đang xử lý ảnh…';
        const { page, analysis } = await addPage(curDoc, blob);
        updateBottom();
        const bad = analysis.issues.filter((i) => i.sev >= 1 && i.code !== 'small_doc');
        if (bad.length) {
          const keep = await ask('Ảnh chưa đạt chất lượng', bad.map((i) => '• ' + esc(i.msg)).join('<br>'), 'Vẫn giữ', 'Chụp lại');
          if (!keep) { await DB.del('pages', page.id); updateBottom(); return; }
        }
        if (analysis.dewarp) toast(analysis.kind === 'curl' ? 'Phát hiện mép giấy quăn/cong – đã tự nắn phẳng' : 'Phát hiện giấy cong – đã tự nắn theo mép');
        if (!analysis.corners) { toast('Không chắc chắn vị trí 4 góc – vui lòng chỉnh tay'); Editor.open(page, 'crop'); return; }
        toast(`Đã chụp trang ${page.idx + 1}`);
      } catch (e) {
        toast(/quota|đầy/i.test(e.message) ? 'Bộ nhớ trình duyệt đã đầy' : 'Lỗi khi chụp: ' + e.message, 4000);
      } finally {
        capturing = false; $('#shutter').classList.remove('busy'); tracker.reset(); cooldown = Date.now() + 2500;
      }
    }
    async function updateBottom() {
      if (!curDoc) return;
      const pages = await DB.pagesOf(curDoc.id);
      $('#camCount').textContent = pages.length;
      $('#camThumb').src = pages.length ? thumbURL(pages[pages.length - 1]) : '';
      $('#camDone').disabled = !pages.length;
    }
    $('#shutter').onclick = () => capture();
    $('#camClose').onclick = () => history.back();
    $('#camDone').onclick = () => { stop(); show('doc'); };
    $('#camAuto').onclick = () => { S.auto = !S.auto; saveSettings(); $('#camAuto').classList.toggle('off', !S.auto); $('#camAuto').textContent = S.auto ? 'Tự động' : 'Thủ công'; };
    $('#camGrid').onclick = () => { S.grid = !S.grid; saveSettings(); };
    $('#camTorch').onclick = async () => { try { torchOn = !torchOn; await track.applyConstraints({ advanced: [{ torch: torchOn }] }); } catch { toast('Thiết bị không hỗ trợ đèn'); } };
    $('#camImport').onchange = async (e) => { const f = [...e.target.files]; e.target.value = ''; if (f.length) { await ingestFiles(curDoc, f); updateBottom(); } };
    document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); else if ($('#camera').classList.contains('active')) start(); });
    return { start, stop };
  })();
  onShow.camera = () => Camera.start();

  // Thước thăng bằng (DeviceOrientation; iOS cần xin quyền khi người dùng bấm)
  let motionAsked = false;
  function requestMotion() {
    if (motionAsked) return; motionAsked = true;
    const D = window.DeviceOrientationEvent;
    if (D && typeof D.requestPermission === 'function') D.requestPermission().catch(() => { });
  }
  window.addEventListener('deviceorientation', (e) => {
    const lv = $('#level');
    if (!S.grid || e.beta == null || !$('#camera').classList.contains('active')) { lv.classList.add('hidden'); return; }
    const b = e.beta, g = e.gamma;
    if (Math.abs(b) > 40 || Math.abs(g) > 40) { lv.classList.add('hidden'); return; } // máy không nằm ngang
    lv.classList.remove('hidden');
    const ok = Math.abs(b) <= 3 && Math.abs(g) <= 3;
    lv.classList.toggle('ok', ok);
    lv.querySelector('i').style.transform = `translate(${Math.max(-1, Math.min(1, g / 15)) * 22}px,${Math.max(-1, Math.min(1, b / 15)) * 22}px)`;
    lv.querySelector('span').textContent = ok ? 'Máy song song giấy' : `Nghiêng ${Math.round(Math.max(Math.abs(b), Math.abs(g)))}°`;
  });

  // ------------------------------------------------------------ TRANG TÀI LIỆU
  const selected = new Set();
  onShow.doc = async () => {
    if (!curDoc) return show('home');
    $('#docName').textContent = curDoc.name;
    const pages = await DB.pagesOf(curDoc.id);
    if (!selected.size || [...selected].some((id) => !pages.find((p) => p.id === id))) { selected.clear(); pages.forEach((p) => selected.add(p.id)); }
    const list = $('#pageList'); list.innerHTML = '';
    if (!pages.length) list.innerHTML = '<p class="muted center">Chưa có trang nào. Bấm “Chụp thêm”.</p>';
    pages.forEach((p, i) => {
      const el = document.createElement('div'); el.className = 'page-item';
      const warn = !p.edit.corners ? '<div class="warn">Chưa crop – nên chỉnh 4 góc</div>'
        : (p.issues || []).some((c) => !['shadow', 'small_doc'].includes(c)) ? '<div class="warn">Có cảnh báo chất lượng</div>' : '';
      const curved = p.edit.dewarp ? '<div class="muted">✓ Đã nắn giấy cong</div>' : '';
      el.innerHTML = `<input type="checkbox" class="sel" ${selected.has(p.id) ? 'checked' : ''}>
        <img src="${thumbURL(p)}" alt=""><div class="info"><b>Trang ${i + 1}</b><small>${MODES.find((m) => m[0] === p.edit.mode)?.[1] || ''}</small>${curved}${warn}</div>
        <div class="ops"><button data-a="up" aria-label="Lên">↑</button><button data-a="down" aria-label="Xuống">↓</button>
        <button data-a="rot" aria-label="Xoay">⟳</button><button data-a="edit" aria-label="Sửa">✏️</button><button data-a="del" aria-label="Xoá">🗑</button></div>`;
      el.querySelector('.sel').onchange = (e) => e.target.checked ? selected.add(p.id) : selected.delete(p.id);
      el.querySelector('img').onclick = () => Editor.open(p);
      el.querySelectorAll('[data-a]').forEach((b) => b.onclick = async () => {
        const a = b.dataset.a;
        if (a === 'edit') return Editor.open(p);
        if (a === 'del') { if (!(await ask(`Xoá trang ${i + 1}?`, 'Ảnh gốc của trang này sẽ bị xoá khỏi máy.', 'Xoá', 'Huỷ', true))) return; await DB.del('pages', p.id); selected.delete(p.id); }
        if (a === 'rot') { p.edit.rotation = ((p.edit.rotation || 0) + 1) % 4; await DB.put('pages', p); await refreshThumb(p); }
        if (a === 'up' || a === 'down') {
          const j = a === 'up' ? i - 1 : i + 1; if (j < 0 || j >= pages.length) return;
          [pages[i], pages[j]] = [pages[j], pages[i]];
        }
        const now = await DB.pagesOf(curDoc.id), order = (a === 'up' || a === 'down') ? pages : now;
        for (let k = 0; k < order.length; k++) { if (order[k].idx !== k) { order[k].idx = k; await DB.put('pages', order[k]); } }
        await touch(curDoc); onShow.doc();
      });
      list.appendChild(el);
    });
  };
  $('#docRename').onclick = async () => { const n = await promptText('Đổi tên tài liệu', curDoc.name); if (n) { curDoc.name = n; await touch(curDoc); onShow.doc(); } };
  $('#docAddCam').onclick = () => { requestMotion(); show('camera'); };
  $('#docImport').onchange = async (e) => { const f = [...e.target.files]; e.target.value = ''; if (f.length) { await ingestFiles(curDoc, f); onShow.doc(); } };
  $('#docExport').onclick = () => { if (!selected.size) return toast('Hãy chọn ít nhất 1 trang'); show('export'); };

  // ------------------------------------------------------------ CHỈNH SỬA
  const Editor = (() => {
    let page = null, prev = null, full = null, hist = [], hi = 0, tab = 'crop', comparing = false, grid = false;
    let renderSeq = 0, renderTimer = null, procCanvas = document.createElement('canvas'), origCanvas = null;
    const cv = $('#edCanvas'), panel = $('#edPanel');
    const P = () => hist[hi];

    async function open(p, startTab) {
      page = p; hist = [JSON.parse(JSON.stringify(p.edit))]; hi = 0; full = null;
      tab = startTab || (p.edit.corners ? 'light' : 'crop');
      show('editor');
      const pages = await DB.pagesOf(p.docId);
      $('#edTitle').textContent = `Trang ${pages.findIndex((x) => x.id === p.id) + 1}`;
      $('#edSpin').classList.remove('hidden');
      prev = await decode(p.blob, 1400);
      origCanvas = toCanvas(prev.rgba, prev.w, prev.h);
      setTab(tab);
    }
    async function getFull() {
      if (!full) full = await decode(page.blob);
      return full;
    }
    function fitCanvas(c, w, h) {
      const v = $('#edView'), s = Math.min(v.clientWidth / w, v.clientHeight / h);
      c.style.width = `${w * s}px`; c.style.height = `${h * s}px`;
    }
    function drawGrid() {
      const g = $('#edGrid'); g.classList.toggle('hidden', !grid || tab === 'crop');
      if (!grid) return;
      g.width = cv.width; g.height = cv.height; g.style.width = cv.style.width; g.style.height = cv.style.height;
      const ctx = g.getContext('2d'); ctx.clearRect(0, 0, g.width, g.height);
      ctx.strokeStyle = 'rgba(0,200,255,.6)'; ctx.lineWidth = Math.max(1, g.width / 600); ctx.beginPath();
      for (let i = 1; i < 8; i++) { ctx.moveTo(g.width * i / 8, 0); ctx.lineTo(g.width * i / 8, g.height); }
      for (let i = 1; i < 11; i++) { ctx.moveTo(0, g.height * i / 11); ctx.lineTo(g.width, g.height * i / 11); }
      ctx.stroke();
    }
    function render(debounce) {
      clearTimeout(renderTimer);
      if (debounce) { renderTimer = setTimeout(() => render(false), 180); return; }
      const seq = ++renderSeq; $('#edSpin').classList.remove('hidden');
      const r = copy(prev.rgba);
      heavy.call('render', { rgba: r, w: prev.w, h: prev.h, params: scaleParams(P(), prev.scale), scale: 1, bicubic: false }, [r.buffer]).then((o) => {
        if (seq !== renderSeq) return;
        toCanvas(o.rgba, o.w, o.h, procCanvas);
        paint(); $('#edSpin').classList.add('hidden');
      }).catch((e) => { $('#edSpin').classList.add('hidden'); toast('Lỗi xử lý ảnh: ' + e.message); });
    }
    function paint() {
      const src = comparing ? origCanvas : procCanvas;
      cv.width = src.width; cv.height = src.height; cv.getContext('2d').drawImage(src, 0, 0);
      fitCanvas(cv, src.width, src.height); drawGrid();
    }
    async function commit(next, debounce) {
      if (JSON.stringify(next) === JSON.stringify(P())) return;
      hist = hist.slice(0, hi + 1); hist.push(next); if (hist.length > 60) hist.shift(); hi = hist.length - 1;
      await persist(); tab === 'crop' ? Corner.draw() : render(debounce); buildPanel();
    }
    async function persist() { page.edit = JSON.parse(JSON.stringify(P())); await DB.put('pages', page); }
    const upd = (patch) => Object.assign(JSON.parse(JSON.stringify(P())), patch);

    function setTab(t) {
      tab = t;
      $$('.tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === t));
      $('#edCorner').classList.toggle('hidden', t !== 'crop');
      cv.classList.toggle('hidden', t === 'crop');
      $('.ed-tools').classList.toggle('hidden', t === 'crop');
      buildPanel();
      if (t === 'crop') { $('#edSpin').classList.add('hidden'); Corner.draw(); } else render();
    }
    function chips(list, cur, cb) {
      return `<div class="chips">${list.map(([v, l]) => `<button data-v="${v}" class="${v === cur ? 'on' : ''}">${l}</button>`).join('')}</div>`;
    }
    function slider(key, label, min, max, step, val) {
      return `<div class="slider"><span>${label}</span><input type="range" data-k="${key}" min="${min}" max="${max}" step="${step}" value="${val}"></div>`;
    }
    function buildPanel() {
      const p = P();
      let h = `<div class="ed-row"><button class="chip-btn" data-act="rotl">⟲ Xoay trái</button><button class="chip-btn" data-act="rotr">⟳ Xoay phải</button>
        <span class="sp"></span><button class="btn small" data-act="done">Xong</button></div>`;
      if (tab === 'crop') {
        h += `<div class="ed-row"><button class="chip-btn" data-act="detect">✨ Tự nhận diện</button><button class="chip-btn" data-act="snap">🧲 Bắt dính mép giấy</button>
          <button class="chip-btn" data-act="dewarp">📖 Nắn giấy cong</button><button class="chip-btn" data-act="full">⛶ Toàn ảnh</button></div>`;
        if (p.dewarp) h += `<div class="ed-row"><span class="muted">✓ Đang nắn ${p.dewarp.type === 'cyl' ? 'mép quăn (3D)' : 'theo mép cong'}</span><button class="chip-btn" data-act="nodewarp">Tắt</button></div>`;
        h += `<div class="muted">Khổ giấy sau khi nắn:</div>${chips(PAPERS, p.paper || 'auto', 'paper')}<div class="muted" id="aspectInfo"></div>`;
      } else if (tab === 'light') {
        h += `<div class="ed-row" style="flex-wrap:nowrap">${slider('fineRotation', 'Làm thẳng (°)', -15, 15, 0.1, p.fineRotation || 0)}<button class="chip-btn" data-act="straight">Tự động</button></div>`;
        h += slider('shadow', 'Giảm bóng', 0, 1, 0.05, p.shadow ?? 0.7) + slider('brightness', 'Độ sáng', -1, 1, 0.05, p.brightness || 0)
          + slider('contrast', 'Tương phản', -1, 1, 0.05, p.contrast || 0) + slider('sharpness', 'Độ nét (giới hạn)', 0, 1, 0.05, p.sharpness || 0)
          + slider('warmth', 'Cân bằng trắng', -1, 1, 0.05, p.warmth || 0);
        h += `<div class="ed-row"><button class="chip-btn" data-act="reset">Đặt lại mặc định</button><button class="chip-btn" data-act="orig">Khôi phục ảnh gốc</button></div>`;
      } else {
        h += chips(MODES, p.mode, 'mode');
        if (p.mode === 'bw' || p.mode === 'gray') h += '<div class="muted">Chế độ này làm mất màu dấu đỏ & chữ ký xanh. Dùng “Scan rõ chữ” hoặc “Màu gốc” để giữ màu.</div>';
      }
      panel.innerHTML = h;
      panel.querySelectorAll('[data-act]').forEach((b) => b.onclick = () => action(b.dataset.act));
      panel.querySelectorAll('.chips').forEach((c) => c.querySelectorAll('button').forEach((b) => b.onclick = () => {
        commit(upd(tab === 'crop' ? { paper: b.dataset.v } : { mode: b.dataset.v }));
      }));
      panel.querySelectorAll('input[type=range]').forEach((r) => {
        r.oninput = () => { hist[hi] = upd({ [r.dataset.k]: parseFloat(r.value) }); render(true); };
        r.onpointerdown = () => { hist = hist.slice(0, hi + 1); hist.push(JSON.parse(JSON.stringify(P()))); hi = hist.length - 1; };
        r.onchange = () => persist();
      });
      if (tab === 'crop') showAspect();
    }
    async function showAspect() {
      const p = P(); if (!p.corners) { $('#aspectInfo') && ($('#aspectInfo').textContent = 'Chưa crop – dùng toàn ảnh.'); return; }
      const a = await heavy.call('aspect', { params: p, w: page.w, h: page.h });
      const el = $('#aspectInfo'); if (!el || !a) return;
      const long = a.ratio >= 1 ? a.ratio : 1 / a.ratio;
      el.textContent = `Tỷ lệ trang 1 : ${long.toFixed(3)}${a.snapped ? ' • khổ ' + ({ a4: 'A4', letter: 'Letter', legal: 'Legal' }[a.snapped]) : ''}`;
    }
    async function action(a) {
      const p = P();
      if (a === 'done') return history.back();
      if (a === 'rotl' || a === 'rotr') return commit(upd({ rotation: (((p.rotation || 0) + (a === 'rotr' ? 1 : 3)) % 4) }));
      if (a === 'full') return commit(upd({ corners: null, dewarp: null }));
      if (a === 'nodewarp') return commit(upd({ dewarp: null }));
      if (a === 'reset') return commit({ corners: p.corners, dewarp: p.dewarp, paper: p.paper, rotation: p.rotation, mode: S.mode });
      if (a === 'orig') return commit({ corners: null, dewarp: null, mode: 'original', shadow: 0, rotation: 0 });
      const pg = progress({ detect: 'Đang nhận diện 4 góc', snap: 'Đang bắt dính mép giấy', dewarp: 'Đang phân tích độ cong', straight: 'Đang đo độ nghiêng dòng chữ' }[a] || '…');
      pg.set('Đang xử lý ở độ phân giải đầy đủ…', 0.4);
      try {
        const f = await getFull(), sc = 1 / f.scale, r = copy(f.rgba);
        const toFull = (q) => q && q.map((x) => ({ x: x.x * sc, y: x.y * sc })), toLim = (q) => q && q.map((x) => ({ x: x.x * f.scale, y: x.y * f.scale }));
        if (a === 'detect') {
          const res = await heavy.call('analyze', { rgba: r, w: f.w, h: f.h }, [r.buffer]);
          pg.close();
          if (!res.corners) return toast('Không nhận diện chắc chắn – hãy kéo 4 góc bằng tay');
          return commit(upd({ corners: toFull(res.corners), dewarp: res.dewarp ? scaleModel(res.dewarp, sc) : null }));
        }
        if (!p.corners && a !== 'straight') { pg.close(); return toast('Hãy đặt 4 góc tài liệu trước'); }
        if (a === 'snap') {
          const q = await heavy.call('snap', { rgba: r, w: f.w, h: f.h, quad: toLim(p.corners) }, [r.buffer]);
          pg.close(); return commit(upd({ corners: toFull(q), dewarp: null }));
        }
        if (a === 'dewarp') {
          const res = await heavy.call('dewarp', { rgba: r, w: f.w, h: f.h, quad: toLim(p.corners) }, [r.buffer]);
          pg.close();
          if (!res.dewarp) return toast('Giấy phẳng – không cần nắn cong');
          toast(res.kind === 'curl' ? 'Đã nắn mép quăn bằng mô hình 3D' : 'Đã nắn theo mép giấy cong');
          return commit(upd({ corners: toFull(res.corners), dewarp: scaleModel(res.dewarp, sc) }));
        }
        if (a === 'straight') {
          const pr = copy(prev.rgba);
          const ang = await heavy.call('straighten', { rgba: pr, w: prev.w, h: prev.h, params: scaleParams(p, prev.scale), scale: 1 }, [pr.buffer]);
          pg.close(); if (!ang) toast('Dòng chữ đã thẳng (hoặc không đủ chữ để đo)');
          return commit(upd({ fineRotation: Math.round(ang * 100) / 100 }));
        }
      } catch (e) { pg.close(); toast('Lỗi: ' + e.message, 4000); }
    }

    // --- chỉnh 4 góc trên ảnh gốc
    const Corner = (() => {
      const c = $('#cornerCanvas'), lp = $('#loupe');
      let drag = -1, q = null, geo = null;
      function quadNow() { const p = P(); return p.corners ? p.corners.map((x) => ({ x: x.x, y: x.y })) : [{ x: 0, y: 0 }, { x: page.w, y: 0 }, { x: page.w, y: page.h }, { x: 0, y: page.h }]; }
      function draw() {
        if (!prev) return;
        if (drag < 0) q = quadNow();
        const dpr = window.devicePixelRatio || 1, W = c.clientWidth, H = c.clientHeight;
        c.width = W * dpr; c.height = H * dpr;
        const pad = 26, s = Math.min((W - 2 * pad) / page.w, (H - 2 * pad) / page.h);
        geo = { s, ox: (W - page.w * s) / 2, oy: (H - page.h * s) / 2 };
        const ctx = c.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
        ctx.drawImage(origCanvas, geo.ox, geo.oy, page.w * s, page.h * s);
        const sp = q.map((p) => [geo.ox + p.x * s, geo.oy + p.y * s]);
        ctx.fillStyle = 'rgba(0,0,0,.45)'; ctx.beginPath(); ctx.rect(0, 0, W, H);
        ctx.moveTo(sp[0][0], sp[0][1]); for (let i = 3; i >= 0; i--) ctx.lineTo(sp[i][0], sp[i][1]); ctx.closePath(); ctx.fill('evenodd');
        ctx.strokeStyle = '#4fc3ff'; ctx.lineWidth = 2.5; ctx.beginPath(); sp.forEach(([x, y], i) => i ? ctx.lineTo(x, y) : ctx.moveTo(x, y)); ctx.closePath(); ctx.stroke();
        for (const [x, y] of sp) { ctx.beginPath(); ctx.arc(x, y, 13, 0, 7); ctx.fillStyle = 'rgba(255,255,255,.9)'; ctx.fill(); ctx.lineWidth = 3; ctx.strokeStyle = '#6C4DFF'; ctx.stroke(); }
      }
      function loupe(p, screenX) {
        lp.classList.remove('hidden');
        const W = c.clientWidth; lp.style.left = screenX < W / 2 ? `${W - 140}px` : '12px';
        lp.width = 256; lp.height = 256; const ctx = lp.getContext('2d');
        const ps = origCanvas.width / page.w, src = 40;
        ctx.fillStyle = '#000'; ctx.fillRect(0, 0, 256, 256);
        ctx.drawImage(origCanvas, p.x * ps - src / 2, p.y * ps - src / 2, src, src, 0, 0, 256, 256);
        ctx.strokeStyle = '#ff5252'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(100, 128); ctx.lineTo(156, 128); ctx.moveTo(128, 100); ctx.lineTo(128, 156); ctx.stroke();
      }
      const toImg = (e) => { const r = c.getBoundingClientRect(); return { x: Math.max(0, Math.min(page.w, (e.clientX - r.left - geo.ox) / geo.s)), y: Math.max(0, Math.min(page.h, (e.clientY - r.top - geo.oy) / geo.s)), sx: e.clientX - r.left }; };
      c.addEventListener('pointerdown', (e) => {
        const p = toImg(e); let best = -1, bd = 44 / geo.s;
        q.forEach((v, i) => { const d = Math.hypot(v.x - p.x, v.y - p.y); if (d < bd) { bd = d; best = i; } });
        if (best >= 0) { drag = best; c.setPointerCapture(e.pointerId); loupe(q[best], p.sx); }
      });
      c.addEventListener('pointermove', (e) => { if (drag < 0) return; const p = toImg(e); q[drag] = { x: p.x, y: p.y }; draw(); loupe(q[drag], p.sx); });
      const end = () => {
        if (drag < 0) return; drag = -1; lp.classList.add('hidden');
        const nq = CV.quadOrder(q);
        if (!CV.isConvex(nq) || CV.quadArea(nq) < 100) { toast('Vùng chọn không hợp lệ (bị xoắn hoặc quá nhỏ)'); draw(); return; }
        commit(upd({ corners: nq, dewarp: null }));
      };
      c.addEventListener('pointerup', end); c.addEventListener('pointercancel', end);
      window.addEventListener('resize', () => { if ($('#editor').classList.contains('active')) tab === 'crop' ? draw() : paint(); });
      return { draw };
    })();

    $$('.tabs button').forEach((b) => b.onclick = () => setTab(b.dataset.tab));
    $('#edUndo').onclick = async () => { if (hi > 0) { hi--; await persist(); tab === 'crop' ? Corner.draw() : render(); buildPanel(); } };
    $('#edRedo').onclick = async () => { if (hi < hist.length - 1) { hi++; await persist(); tab === 'crop' ? Corner.draw() : render(); buildPanel(); } };
    const cmp = $('#edCompare');
    cmp.onpointerdown = () => { comparing = true; paint(); };
    cmp.onpointerup = cmp.onpointerleave = cmp.onpointercancel = () => { if (comparing) { comparing = false; paint(); } };
    $('#edGridBtn').onclick = () => { grid = !grid; drawGrid(); };
    $('#edBack').onclick = () => history.back();
    async function close() { if (page) { await persist(); await refreshThumb(page); page = null; prev = null; full = null; } }
    return { open, close };
  })();
  window.__editorClose = () => Editor.close();

  // ------------------------------------------------------------ XUẤT FILE
  const ex = { format: 'pdf', size: 'a4', pdfq: '95' };
  onShow.export = () => {
    $('#exName').value = curDoc ? curDoc.name : 'TaiLieu';
    $('#exResult').innerHTML = '';
    syncExport();
  };
  function bindChips(sel, key) {
    $$(`${sel} button`).forEach((b) => b.onclick = () => { ex[key] = b.dataset.v; syncExport(); });
  }
  bindChips('#exFormat', 'format'); bindChips('#exSize', 'size'); bindChips('#exPdfQ', 'pdfq');
  function syncExport() {
    for (const [sel, key] of [['#exFormat', 'format'], ['#exSize', 'size'], ['#exPdfQ', 'pdfq']]) $$(`${sel} button`).forEach((b) => b.classList.toggle('on', b.dataset.v === ex[key]));
    $('#exPdfOpts').classList.toggle('hidden', ex.format !== 'pdf');
    $('#exJpgOpts').classList.toggle('hidden', ex.format !== 'jpg');
    $('#exNote').textContent = {
      pdf: 'PDF dùng ảnh đã xử lý ở độ phân giải đầy đủ. Khổ A4: trang A4, ảnh vừa khít không kéo giãn.',
      jpg: 'Mã hoá JPEG đúng 1 lần từ ảnh đã xử lý. Dưới 85 có thể làm nhoè nét chữ nhỏ.',
      png: 'PNG không nén mất dữ liệu, giữ nguyên độ phân giải. File lớn hơn JPG.',
      orig: 'Ảnh gốc nguyên vẹn từng byte: không crop, không chỉnh sáng, không giảm kích thước.',
    }[ex.format];
  }
  $('#exJpgQ').oninput = (e) => { $('#exJpgQv').textContent = e.target.value; };

  async function buildExport() {
    const pages = (await DB.pagesOf(curDoc.id)).filter((p) => selected.has(p.id));
    if (!pages.length) throw new Error('Chưa chọn trang');
    const base = sanitize($('#exName').value || curDoc.name), files = [];
    const pg = progress('Đang xuất file');
    try {
      if (ex.format === 'orig') {
        pages.forEach((p, i) => {
          const ext = (p.blob.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg');
          files.push(new File([p.blob], `${base}${pages.length > 1 ? '_' + two(i + 1) : ''}.${ext}`, { type: p.blob.type || 'image/jpeg' }));
        });
        return files;
      }
      const pdfPages = [];
      for (let i = 0; i < pages.length; i++) {
        pg.set(`Xử lý trang ${i + 1}/${pages.length} ở độ phân giải đầy đủ…`, i / pages.length);
        const f = await decode(pages[i].blob);
        const o = await heavy.call('render', { rgba: f.rgba, w: f.w, h: f.h, params: scaleParams(pages[i].edit, f.scale), scale: 1, bicubic: true }, [f.rgba.buffer]);
        const canvas = toCanvas(o.rgba, o.w, o.h);
        const suffix = pages.length > 1 ? '_' + two(i + 1) : '';
        if (ex.format === 'jpg') files.push(new File([await toBlob(canvas, 'image/jpeg', +$('#exJpgQ').value / 100)], `${base}${suffix}.jpg`, { type: 'image/jpeg' }));
        else if (ex.format === 'png') files.push(new File([await toBlob(canvas, 'image/png')], `${base}${suffix}.png`, { type: 'image/png' }));
        else if (ex.pdfq === 'lossless' && typeof CompressionStream !== 'undefined') {
          const rgb = new Uint8Array(o.w * o.h * 3);
          for (let k = 0, j = 0; k < rgb.length; k += 3, j += 4) { rgb[k] = o.rgba[j]; rgb[k + 1] = o.rgba[j + 1]; rgb[k + 2] = o.rgba[j + 2]; }
          pdfPages.push({ w: o.w, h: o.h, rgb });
        } else {
          const jb = await toBlob(canvas, 'image/jpeg', (ex.pdfq === 'lossless' ? 95 : +ex.pdfq) / 100);
          pdfPages.push({ w: o.w, h: o.h, jpeg: new Uint8Array(await jb.arrayBuffer()) });
        }
      }
      if (ex.format === 'pdf') {
        pg.set('Đang tạo PDF…', 0.95);
        const blob = await PDFW.build(pdfPages, { size: ex.size === 'auto' ? null : ex.size, title: base, author: 'APP scan PDF' });
        files.push(new File([blob], `${base}.pdf`, { type: 'application/pdf' }));
      }
      curDoc.status = 'saved'; await touch(curDoc);
      return files;
    } finally { pg.close(); }
  }
  function showResult(files, how) {
    const total = files.reduce((s, f) => s + f.size, 0);
    $('#exResult').innerHTML = `<div class="res">✅ ${how}: ${files.map((f) => `<b>${esc(f.name)}</b>`).join(', ')}<br>Tổng dung lượng ${fmtBytes(total)}</div>`;
  }
  $('#exSave').onclick = async () => {
    try {
      const files = await buildExport();
      for (const f of files) {
        const a = document.createElement('a'); a.href = URL.createObjectURL(f); a.download = f.name;
        document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 30000);
        await new Promise((r) => setTimeout(r, 300));
      }
      showResult(files, 'Đã lưu');
    } catch (e) { toast('Xuất file lỗi: ' + e.message, 4000); }
  };
  $('#exShare').onclick = async () => {
    try {
      const files = await buildExport();
      if (navigator.canShare && navigator.canShare({ files })) {
        try { await navigator.share({ files, title: files[0].name }); showResult(files, 'Đã chia sẻ'); }
        catch (e) { if (e.name !== 'AbortError') throw e; }
      } else {
        toast('Trình duyệt chưa hỗ trợ chia sẻ file – đã lưu về máy để bạn gửi.', 4000);
        $('#exSave').onclick();
      }
    } catch (e) { toast('Chia sẻ lỗi: ' + e.message, 4000); }
  };

  // ------------------------------------------------------------ THƯ VIỆN
  onShow.library = async () => {
    const q = ($('#libSearch').value || '').toLowerCase().trim();
    const docs = (await DB.all('docs')).sort((a, b) => b.updatedAt - a.updatedAt).filter((d) => !q || d.name.toLowerCase().includes(q));
    const list = $('#libList'); list.innerHTML = docs.length ? '' : '<p class="muted center">Chưa có tài liệu.</p>';
    for (const d of docs) {
      const pages = await DB.pagesOf(d.id); if (!pages.length) continue;
      const el = docItem(d, pages);
      const del = document.createElement('button'); del.className = 'icon-btn'; del.textContent = '🗑'; del.setAttribute('aria-label', 'Xoá');
      del.onclick = async (e) => {
        e.stopPropagation();
        if (!(await ask('Xoá tài liệu?', `Xoá “${esc(d.name)}” cùng ${pages.length} ảnh gốc khỏi máy.`, 'Xoá', 'Huỷ', true))) return;
        for (const p of pages) await DB.del('pages', p.id);
        await DB.del('docs', d.id); onShow.library();
      };
      el.lastElementChild.replaceWith(del); list.appendChild(el);
    }
  };
  $('#libSearch').oninput = () => onShow.library();

  // ------------------------------------------------------------ CÀI ĐẶT
  onShow.settings = async () => {
    $('#setAuto').checked = S.auto; $('#setGrid').checked = S.grid;
    $('#setMode').innerHTML = MODES.map(([v, l]) => `<button data-v="${v}" class="${v === S.mode ? 'on' : ''}">${l}</button>`).join('');
    $$('#setMode button').forEach((b) => b.onclick = () => { S.mode = b.dataset.v; saveSettings(); onShow.settings(); });
    let txt = 'Ảnh và tài liệu lưu trong bộ nhớ trình duyệt của máy này.';
    try {
      const e = await navigator.storage.estimate();
      txt += ` Đang dùng ${fmtBytes(e.usage || 0)} / ${fmtBytes(e.quota || 0)}.`;
      if ((e.quota - e.usage) < 300 * 1048576) txt += ' ⚠️ Bộ nhớ gần đầy.';
      if (navigator.storage.persisted && await navigator.storage.persisted()) txt += ' ✓ Đã bật giữ dữ liệu lâu dài.';
    } catch { /* không hỗ trợ */ }
    $('#storageInfo').textContent = txt;
  };
  $('#setAuto').onchange = (e) => { S.auto = e.target.checked; saveSettings(); };
  $('#setGrid').onchange = (e) => { S.grid = e.target.checked; saveSettings(); };
  $('#btnPersist').onclick = async () => {
    try { const ok = await navigator.storage.persist(); toast(ok ? 'Đã bật giữ dữ liệu lâu dài' : 'Trình duyệt chưa cho phép – hãy cài app lên màn hình chính'); onShow.settings(); }
    catch { toast('Trình duyệt không hỗ trợ'); }
  };

  // ------------------------------------------------------------ PWA
  let deferredPrompt = null;
  const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent);
  const standalone = window.matchMedia('(display-mode: standalone)').matches || navigator.standalone;
  window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); deferredPrompt = e; $('#installBox').classList.remove('hidden'); });
  if (isIOS && !standalone) {
    $('#installBox').classList.remove('hidden');
    $('#installText').innerHTML = 'Trên iPhone: bấm nút <b>Chia sẻ</b> của Safari → <b>Thêm vào MH chính</b>.';
    $('#btnInstall').classList.add('hidden');
  }
  $('#btnInstall').onclick = async () => {
    if (!deferredPrompt) return;
    deferredPrompt.prompt(); await deferredPrompt.userChoice; deferredPrompt = null; $('#installBox').classList.add('hidden');
  };
  if ('serviceWorker' in navigator && location.protocol !== 'file:') navigator.serviceWorker.register('sw.js').catch(() => { });

  onShow.home();
})();
