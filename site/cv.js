/* APP scan PDF – lõi xử lý ảnh cho bản web (port từ lib/core/*.dart và
 * lib/services/imaging/*.dart). Chạy được trong Web Worker và Node (kiểm thử).
 * Chỉ dùng biến đổi ảnh cổ điển: không AI, không vẽ thêm, không sửa nét mực. */
(function (root) {
  'use strict';
  const M = Math;

  // ---------------------------------------------------------------- hình học
  const P = (x, y) => ({ x, y });
  const dist = (a, b) => M.hypot(a.x - b.x, a.y - b.y);

  function quadOrder(p) {
    const cx = (p[0].x + p[1].x + p[2].x + p[3].x) / 4;
    const cy = (p[0].y + p[1].y + p[2].y + p[3].y) / 4;
    const s = p.slice().sort((a, b) => M.atan2(a.y - cy, a.x - cx) - M.atan2(b.y - cy, b.x - cx));
    let st = 0, best = Infinity;
    for (let i = 0; i < 4; i++) { const v = s[i].x + s[i].y; if (v < best) { best = v; st = i; } }
    return [0, 1, 2, 3].map(i => s[(st + i) % 4]);
  }
  function quadArea(q) {
    let a = 0;
    for (let i = 0; i < 4; i++) { const p = q[i], r = q[(i + 1) % 4]; a += p.x * r.y - r.x * p.y; }
    return M.abs(a) / 2;
  }
  function isConvex(q) {
    let sign = 0;
    for (let i = 0; i < 4; i++) {
      const a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
      const cr = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      if (M.abs(cr) < 1e-9) return false;
      const s = M.sign(cr);
      if (!sign) sign = s; else if (s !== sign) return false;
    }
    return true;
  }
  function minAngle(q) {
    let m = 180;
    for (let i = 0; i < 4; i++) {
      const pr = q[(i + 3) % 4], c = q[i], nx = q[(i + 1) % 4];
      const v1x = pr.x - c.x, v1y = pr.y - c.y, v2x = nx.x - c.x, v2y = nx.y - c.y;
      const d = M.sqrt((v1x * v1x + v1y * v1y) * (v2x * v2x + v2y * v2y));
      if (!d) return 0;
      m = M.min(m, M.acos(M.max(-1, M.min(1, (v1x * v2x + v1y * v2y) / d))) * 180 / M.PI);
    }
    return m;
  }
  const scaleQuad = (q, s) => q.map(p => P(p.x * s, p.y * s));

  /** Homography H: src[i] → dst[i]. Trả về mảng 9 phần tử. */
  function homography(src, dst) {
    const a = [];
    for (let i = 0; i < 4; i++) {
      const x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
      a.push([x, y, 1, 0, 0, 0, -u * x, -u * y, u]);
      a.push([0, 0, 0, x, y, 1, -v * x, -v * y, v]);
    }
    for (let c = 0; c < 8; c++) {
      let p = c;
      for (let r = c + 1; r < 8; r++) if (M.abs(a[r][c]) > M.abs(a[p][c])) p = r;
      if (M.abs(a[p][c]) < 1e-12) throw new Error('homography suy biến');
      [a[c], a[p]] = [a[p], a[c]];
      for (let r = 0; r < 8; r++) {
        if (r === c) continue;
        const f = a[r][c] / a[c][c];
        if (!f) continue;
        for (let k = c; k < 9; k++) a[r][k] -= f * a[c][k];
      }
    }
    const h = new Float64Array(9);
    for (let i = 0; i < 8; i++) h[i] = a[i][8] / a[i][i];
    h[8] = 1;
    return h;
  }
  const happly = (h, x, y) => {
    const w = h[6] * x + h[7] * y + h[8];
    return P((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w);
  };
  const UNIT = [P(0, 0), P(1, 0), P(1, 1), P(0, 1)];

  // ------------------------------------------------------------ ảnh cơ bản
  /** RGBA (Uint8ClampedArray) → xám. */
  function toGray(rgba, w, h) {
    const g = new Uint8Array(w * h);
    for (let i = 0, j = 0; i < g.length; i++, j += 4) g[i] = (rgba[j] * 299 + rgba[j + 1] * 587 + rgba[j + 2] * 114) / 1000 | 0;
    return g;
  }
  /** Thu nhỏ xám theo trung bình khối (chất lượng tốt cho nhận diện). */
  function downGray(g, w, h, maxSide) {
    const s = M.min(1, maxSide / M.max(w, h));
    const sw = M.max(1, M.round(w * s)), sh = M.max(1, M.round(h * s));
    const out = new Uint8Array(sw * sh);
    for (let y = 0; y < sh; y++) {
      const y0 = M.floor(y / s), y1 = M.min(h, M.max(y0 + 1, M.floor((y + 1) / s)));
      for (let x = 0; x < sw; x++) {
        const x0 = M.floor(x / s), x1 = M.min(w, M.max(x0 + 1, M.floor((x + 1) / s)));
        let sum = 0, n = 0;
        for (let yy = y0; yy < y1; yy += 1) for (let xx = x0; xx < x1; xx += 1) { sum += g[yy * w + xx]; n++; }
        out[y * sw + x] = n ? sum / n : 0;
      }
    }
    return { g: out, w: sw, h: sh, s: sw / w };
  }
  function boxBlur(src, w, h, r) {
    const tmp = new Uint8Array(src.length), out = new Uint8Array(src.length), win = 2 * r + 1;
    const cl = (v, a, b) => v < a ? a : v > b ? b : v;
    for (let y = 0; y < h; y++) {
      const row = y * w; let sum = 0;
      for (let k = -r; k <= r; k++) sum += src[row + cl(k, 0, w - 1)];
      for (let x = 0; x < w; x++) {
        tmp[row + x] = sum / win;
        sum += src[row + cl(x + r + 1, 0, w - 1)] - src[row + cl(x - r, 0, w - 1)];
      }
    }
    for (let x = 0; x < w; x++) {
      let sum = 0;
      for (let k = -r; k <= r; k++) sum += tmp[cl(k, 0, h - 1) * w + x];
      for (let y = 0; y < h; y++) {
        out[y * w + x] = sum / win;
        sum += tmp[cl(y + r + 1, 0, h - 1) * w + x] - tmp[cl(y - r, 0, h - 1) * w + x];
      }
    }
    return out;
  }
  function otsu(g) {
    const hist = new Float64Array(256);
    for (let i = 0; i < g.length; i++) hist[g[i]]++;
    let sumAll = 0; for (let i = 0; i < 256; i++) sumAll += i * hist[i];
    let sumB = 0, wB = 0, best = 0, t = 127;
    for (let i = 0; i < 256; i++) {
      wB += hist[i]; if (!wB) continue;
      const wF = g.length - wB; if (!wF) break;
      sumB += i * hist[i];
      const mB = sumB / wB, mF = (sumAll - sumB) / wF, b = wB * wF * (mB - mF) * (mB - mF);
      if (b > best) { best = b; t = i; }
    }
    return t;
  }
  function lapVar(g, w, h) {
    let s = 0, s2 = 0, n = 0;
    for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
      const i = y * w + x, l = 4 * g[i] - g[i - 1] - g[i + 1] - g[i - w] - g[i + w];
      s += l; s2 += l * l; n++;
    }
    if (!n) return 0;
    const m = s / n; return s2 / n - m * m;
  }

  // ------------------------------------------------------------ nhận diện
  function convexHull(pts) {
    const p = pts.slice().sort((a, b) => a.x !== b.x ? a.x - b.x : a.y - b.y);
    const cr = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    const lo = [], up = [];
    for (const q of p) { while (lo.length >= 2 && cr(lo[lo.length - 2], lo[lo.length - 1], q) <= 0) lo.pop(); lo.push(q); }
    for (let i = p.length - 1; i >= 0; i--) { const q = p[i]; while (up.length >= 2 && cr(up[up.length - 2], up[up.length - 1], q) <= 0) up.pop(); up.push(q); }
    lo.pop(); up.pop();
    return lo.concat(up);
  }
  function maxAreaQuad(hull) {
    if (hull.length < 4) return null;
    const arg = f => { let bi = 0, bv = -Infinity; hull.forEach((p, i) => { const v = f(p); if (v > bv) { bv = v; bi = i; } }); return bi; };
    const idx = [arg(p => -(p.x + p.y)), arg(p => p.x - p.y), arg(p => p.x + p.y), arg(p => p.y - p.x)];
    const area = id => { let a = 0; for (let i = 0; i < 4; i++) { const p = hull[id[i]], q = hull[id[(i + 1) % 4]]; a += p.x * q.y - q.x * p.y; } return M.abs(a) / 2; };
    let best = area(idx);
    for (let it = 0; it < 4; it++) {
      let imp = false;
      for (let k = 0; k < 4; k++) for (let c = 0; c < hull.length; c++) {
        if (idx.includes(c)) continue;
        const t = idx.slice(); t[k] = c;
        const a = area(t);
        if (a > best + 1e-6) {
          if (!isConvex(quadOrder(t.map(i => hull[i])))) continue;
          best = a; idx[k] = c; imp = true;
        }
      }
      if (!imp) break;
    }
    if (new Set(idx).size < 4) return null;
    return quadOrder(idx.map(i => hull[i]));
  }

  const RELIABLE = 0.62;

  function detectPolarity(g, w, h, t, bright) {
    const n = w * h, mask = new Uint8Array(n);
    for (let i = 0; i < n; i++) mask[i] = (bright ? g[i] > t : g[i] <= t) ? 1 : 0;
    // thành phần liên thông lớn nhất
    const lab = new Int32Array(n), stack = new Int32Array(n);
    let label = 0, bestL = 0, bestS = 0;
    for (let s = 0; s < n; s++) {
      if (!mask[s] || lab[s]) continue;
      label++; let sp = 0, size = 0; stack[sp++] = s; lab[s] = label;
      while (sp) {
        const i = stack[--sp]; size++; const x = i % w;
        if (x > 0 && mask[i - 1] && !lab[i - 1]) { lab[i - 1] = label; stack[sp++] = i - 1; }
        if (x < w - 1 && mask[i + 1] && !lab[i + 1]) { lab[i + 1] = label; stack[sp++] = i + 1; }
        if (i >= w && mask[i - w] && !lab[i - w]) { lab[i - w] = label; stack[sp++] = i - w; }
        if (i < n - w && mask[i + w] && !lab[i + w]) { lab[i + w] = label; stack[sp++] = i + w; }
      }
      if (size > bestS) { bestS = size; bestL = label; }
    }
    if (!bestS) return null;
    // lấp lỗ
    const out = new Uint8Array(n); let sp = 0;
    const push = i => { if (lab[i] !== bestL && !out[i]) { out[i] = 1; stack[sp++] = i; } };
    for (let x = 0; x < w; x++) { push(x); push((h - 1) * w + x); }
    for (let y = 0; y < h; y++) { push(y * w); push(y * w + w - 1); }
    while (sp) { const i = stack[--sp], x = i % w; if (x > 0) push(i - 1); if (x < w - 1) push(i + 1); if (i >= w) push(i - w); if (i < n - w) push(i + w); }
    const filled = new Uint8Array(n); let fa = 0;
    for (let i = 0; i < n; i++) { filled[i] = out[i] ? 0 : 1; fa += filled[i]; }
    const fill = fa / n;
    if (fill < 0.08) return { quad: null, conf: 0, issues: ['too_small'], fill, boundary: [] };
    const bnd = [];
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = y * w + x; if (!filled[i]) continue;
      if (x === 0 || y === 0 || x === w - 1 || y === h - 1 || !filled[i - 1] || !filled[i + 1] || !filled[i - w] || !filled[i + w]) bnd.push(P(x + 0.5, y + 0.5));
    }
    if (bnd.length < 8) return null;
    let hull = convexHull(bnd);
    if (hull.length > 240) { const st = hull.length / 240, hh = []; for (let i = 0; i < hull.length; i += st) hh.push(hull[M.floor(i)]); hull = hh; }
    const q = maxAreaQuad(hull);
    if (!q || !isConvex(q)) return null;
    const qa = quadArea(q), issues = [];
    const sol = M.min(1, fa / M.max(1, qa)), qf = qa / n;
    if (qf > 0.985) return { quad: null, conf: 0, issues: ['no_document'], fill: qf, boundary: [] };
    let sIn = 0, cIn = 0, sOut = 0, cOut = 0;
    for (let i = 0; i < n; i += 3) { if (filled[i]) { sIn += g[i]; cIn++; } else { sOut += g[i]; cOut++; } }
    const contrast = cIn && cOut ? M.abs(sIn / cIn - sOut / cOut) : 0;
    const cs = M.min(1, contrast / 45); if (cs < 0.5) issues.push('low_contrast');
    const as = M.max(0, M.min(1, (minAngle(q) - 35) / 35));
    let onEdge = 0; for (const p of q) if (p.x <= 2 || p.y <= 2 || p.x >= w - 3 || p.y >= h - 3) onEdge++;
    let ep = 1; if (onEdge) { issues.push('corner_out_of_frame'); ep = onEdge >= 2 ? 0.45 : 0.7; }
    if (sol < 0.88) issues.push('occluded');
    const ss = M.max(0, M.min(1, (qf - 0.08) / 0.17)); if (qf < 0.2) issues.push('too_small');
    const conf = M.pow(sol, 3) * (0.4 + 0.6 * cs) * as * ep * (0.5 + 0.5 * ss);
    const step = M.ceil(bnd.length / 3000), boundary = step <= 1 ? bnd : bnd.filter((_, i) => i % step === 0);
    return { quad: q, conf: M.max(0, M.min(1, conf)), issues, fill: qf, boundary };
  }

  /** Nhận diện tài liệu trên ảnh xám nhỏ (~320–720px). */
  function detect(gray, w, h) {
    if (w < 16 || h < 16) return { quad: null, conf: 0, issues: ['no_document'], fill: 0, boundary: [] };
    const b = boxBlur(boxBlur(gray, w, h, 2), w, h, 2), t = otsu(b);
    let best = { quad: null, conf: 0, issues: ['no_document'], fill: 0, boundary: [] };
    for (const bright of [true, false]) {
      const r = detectPolarity(b, w, h, t, bright);
      if (r && r.conf > best.conf) best = r;
    }
    best.reliable = !!best.quad && best.conf >= RELIABLE;
    return best;
  }

  /** Theo dõi ổn định 4 góc giữa các khung (toạ độ chuẩn hoá 0..1). */
  function Tracker(required = 8, maxMove = 0.018, smooth = 0.45) {
    let q = null, stable = 0, miss = 0;
    return {
      update(r) {
        if (!r.reliable) { miss++; stable = 0; if (miss > 4) q = null; return; }
        miss = 0;
        if (!q) { q = r.quad; stable = 0; return; }
        let mv = 0; for (let i = 0; i < 4; i++) mv = M.max(mv, dist(q[i], r.quad[i]));
        q = q.map((p, i) => P(p.x + (r.quad[i].x - p.x) * smooth, p.y + (r.quad[i].y - p.y) * smooth));
        stable = mv / M.SQRT2 <= maxMove ? stable + 1 : 0;
      },
      reset() { q = null; stable = 0; miss = 0; },
      get quad() { return q; },
      get stable() { return stable >= required; },
      get progress() { return M.min(1, stable / required); },
    };
  }

  // ------------------------------------------------------ tinh chỉnh cạnh
  function sampleG(g, w, h, x, y) {
    if (x < 0) x = 0; if (y < 0) y = 0; if (x > w - 1.001) x = w - 1.001; if (y > h - 1.001) y = h - 1.001;
    const x0 = x | 0, y0 = y | 0, fx = x - x0, fy = y - y0, i = y0 * w + x0;
    const a = g[i] + (g[i + 1] - g[i]) * fx, b = g[i + w] + (g[i + w + 1] - g[i + w]) * fx;
    return a + (b - a) * fy;
  }
  function fitLine(pts) {
    if (pts.length < 2) return null;
    let cx = 0, cy = 0; for (const p of pts) { cx += p.x; cy += p.y; } cx /= pts.length; cy /= pts.length;
    let sxx = 0, sxy = 0, syy = 0;
    for (const p of pts) { const dx = p.x - cx, dy = p.y - cy; sxx += dx * dx; sxy += dx * dy; syy += dy * dy; }
    const th = 0.5 * M.atan2(2 * sxy, sxx - syy);
    return { c: P(cx, cy), d: P(M.cos(th), M.sin(th)) };
  }
  function intersect(l1, l2) {
    const det = l1.d.x * (-l2.d.y) - (-l2.d.x) * l1.d.y;
    if (M.abs(det) < 1e-9) return null;
    const rx = l2.c.x - l1.c.x, ry = l2.c.y - l1.c.y, s = (rx * (-l2.d.y) - (-l2.d.x) * ry) / det;
    return P(l1.c.x + l1.d.x * s, l1.c.y + l1.d.y * s);
  }
  /** Chọn biên mép giấy trong 1 mặt cắt: biên NGOÀI CÙNG (offset âm = phía ngoài)
   *  có gradient đúng chiều và ≥ 50% biên mạnh nhất. Tránh bám vào dòng chữ sát mép. */
  function pickEdge(prof, grad, sg) {
    const n = prof.length; let gmax = 4;
    for (let o = 2; o < n - 2; o++) { const v = grad[o] * sg; if (v > gmax) gmax = v; }
    if (gmax <= 4) return null;
    for (let o = 2; o < n - 2; o++) {
      const v = grad[o] * sg;
      if (v >= 0.5 * gmax && v >= grad[o - 1] * sg && v >= grad[o + 1] * sg) {
        const a = grad[o - 1] * sg, c = grad[o + 1] * sg, den = a - 2 * v + c;
        const sub = M.max(-0.5, M.min(0.5, M.abs(den) > 1e-9 ? 0.5 * (a - c) / den : 0));
        return { o: o + sub, v };
      }
    }
    return null;
  }
  /** Chiều gradient: +1 nếu phía trong (giấy) sáng hơn phía ngoài. */
  function insideSign(profiles, steps) {
    let d = 0;
    for (const p of profiles) { let a = 0, b = 0; for (let o = 1; o <= steps; o++) { a += p[steps + o]; b += p[steps - o]; } d += a - b; }
    return d >= 0 ? 1 : -1;
  }
  function refineQuad(g, w, h, q) {
    const r = M.max(6, 0.012 * M.hypot(w, h)), steps = M.floor(r);
    const cx = (q[0].x + q[1].x + q[2].x + q[3].x) / 4, cy = (q[0].y + q[1].y + q[2].y + q[3].y) / 4;
    const lines = [null, null, null, null]; let refined = 0;
    const prof = new Float64Array(2 * steps + 1), grad = new Float64Array(2 * steps + 1);
    for (let i = 0; i < 4; i++) {
      const p0 = q[i], p1 = q[(i + 1) % 4], len = dist(p0, p1);
      if (len < 10) continue;
      const tx = (p1.x - p0.x) / len, ty = (p1.y - p0.y) / len;
      let nx = -ty, ny = tx;
      if ((cx - (p0.x + p1.x) / 2) * nx + (cy - (p0.y + p1.y) / 2) * ny < 0) { nx = -nx; ny = -ny; }
      const k = M.max(20, M.min(200, len / 8)) | 0;
      const profs = [], bases = [];
      for (let j = 0; j < k; j++) {
        const s = 0.08 + 0.84 * j / (k - 1), bx = p0.x + (p1.x - p0.x) * s, by = p0.y + (p1.y - p0.y) * s;
        const pr = new Float64Array(2 * steps + 1);
        for (let o = -steps; o <= steps; o++) {
          const px = bx + nx * o, py = by + ny * o;
          pr[o + steps] = (sampleG(g, w, h, px - tx * 1.5, py - ty * 1.5) + sampleG(g, w, h, px, py) + sampleG(g, w, h, px + tx * 1.5, py + ty * 1.5)) / 3;
        }
        profs.push(pr); bases.push(P(bx, by));
      }
      const sg = insideSign(profs, steps);
      let pts = [];
      for (let j = 0; j < k; j++) {
        const pr = profs[j];
        for (let o = 1; o < pr.length - 1; o++) grad[o] = (pr[o + 1] - pr[o - 1]) / 2;
        const e = pickEdge(pr, grad, sg);
        if (e) { const d = e.o - steps; pts.push(P(bases[j].x + nx * d, bases[j].y + ny * d)); }
      }
      if (pts.length < k * 0.4) continue;
      let line = fitLine(pts);
      for (let it = 0; it < 3 && line; it++) {
        const res = pts.map(p => M.abs((p.x - line.c.x) * -line.d.y + (p.y - line.c.y) * line.d.x));
        const sorted = res.slice().sort((a, b) => a - b), thr = M.max(1, 2.5 * sorted[sorted.length >> 1]);
        const keep = pts.filter((_, m) => res[m] <= thr);
        if (keep.length < k * 0.35) break;
        pts = keep; line = fitLine(pts);
      }
      lines[i] = line; if (line) refined++;
    }
    const out = q.slice();
    for (let i = 0; i < 4; i++) {
      const la = lines[(i + 3) % 4], lb = lines[i];
      if (!la || !lb) continue;
      const p = intersect(la, lb);
      if (!p || dist(p, q[i]) > 2 * r) continue;
      out[i] = P(M.max(0, M.min(w, p.x)), M.max(0, M.min(h, p.y)));
    }
    const nq = quadOrder(out);
    if (!isConvex(nq) || quadArea(nq) < 0.5 * quadArea(q)) return { quad: q, sides: 0 };
    return { quad: nq, sides: refined };
  }

  // ------------------------------------------------------------ tỷ lệ thật
  const PAPER = { a4: M.SQRT2, letter: 11 / 8.5, legal: 14 / 8.5 };
  const focalFrom35 = (f35, w, h) => f35 * M.hypot(w, h) / 43.267;
  const defaultFocal = (w, h) => focalFrom35(26, w, h);
  function naiveRatio(q) {
    return M.max(dist(q[0], q[1]), dist(q[3], q[2])) / M.max(dist(q[0], q[3]), dist(q[1], q[2]));
  }
  function snapAspect(measured, paper = 'auto') {
    if (paper === 'free') return { ratio: measured, measured, snapped: null };
    const long = measured >= 1 ? measured : 1 / measured;
    if (paper !== 'auto') { const pr = PAPER[paper]; return { ratio: measured >= 1 ? pr : 1 / pr, measured, snapped: paper }; }
    let best = null, be = Infinity;
    for (const k of ['a4', 'letter', 'legal']) {
      const e = M.abs(long / PAPER[k] - 1), tol = k === 'a4' ? 0.06 : 0.03;
      if (e <= tol && e < be) { best = k; be = e; }
    }
    if (!best) return { ratio: measured, measured, snapped: null };
    return { ratio: measured >= 1 ? PAPER[best] : 1 / PAPER[best], measured, snapped: best };
  }
  function estimateAspect(q, W, H, focal, paper = 'auto') {
    const u0 = W / 2, v0 = H / 2;
    const m = p => [p.x - u0, p.y - v0, 1];
    const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    const m1 = m(q[0]), m2 = m(q[1]), m3 = m(q[3]), m4 = m(q[2]);
    const c14 = cross(m1, m4), d2 = dot(cross(m2, m4), m3), d3 = dot(cross(m3, m4), m2);
    let measured, src = 'default';
    if (M.abs(d2) < 1e-9 || M.abs(d3) < 1e-9) measured = naiveRatio(q);
    else {
      const k2 = dot(c14, m3) / d2, k3 = dot(c14, m2) / d3;
      const n2 = [0, 1, 2].map(i => k2 * m2[i] - m1[i]), n3 = [0, 1, 2].map(i => k3 * m3[i] - m1[i]);
      const L = M.max(W, H);
      let f2;
      if (focal) { f2 = focal * focal; src = 'exif'; }
      else {
        const f0 = defaultFocal(W, H); f2 = f0 * f0;
        const c2 = M.abs(n2[2]) * L / M.max(1e-9, M.hypot(n2[0], n2[1]));
        const c3 = M.abs(n3[2]) * L / M.max(1e-9, M.hypot(n3[0], n3[1]));
        if (c2 > 0.08 && c3 > 0.08) {
          const fc2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2]);
          if (fc2 > 0) { const fc = M.sqrt(fc2); if (fc >= 0.5 * L && fc <= 1.6 * L) { f2 = fc2; src = 'quad'; } }
        }
      }
      const num = (n2[0] * n2[0] + n2[1] * n2[1]) / f2 + n2[2] * n2[2];
      const den = (n3[0] * n3[0] + n3[1] * n3[1]) / f2 + n3[2] * n3[2];
      measured = num > 0 && den > 0 ? M.sqrt(num / den) : naiveRatio(q);
      if (!isFinite(measured) || measured < 0.05 || measured > 20) measured = naiveRatio(q);
    }
    const r = snapAspect(measured, paper); r.source = src; return r;
  }
  function outputSize(q, ratio) {
    const wm = M.max(dist(q[0], q[1]), dist(q[3], q[2])), hm = M.max(dist(q[0], q[3]), dist(q[1], q[2]));
    const w = M.max(wm, hm * ratio);
    return [M.max(1, M.round(w)), M.max(1, M.round(w / ratio))];
  }

  // ------------------------------------------------------- nắn giấy cong
  const NS = 33, CURL = 0.006, SIDES = ['top', 'right', 'bottom', 'left'];
  function polyfit(t, d, deg) {
    const n = deg + 1;
    if (t.length < n) return new Array(n).fill(0);
    const a = Array.from({ length: n }, () => new Float64Array(n + 1));
    for (let i = 0; i < t.length; i++) {
      const pw = new Float64Array(2 * n); pw[0] = 1;
      for (let k = 1; k < 2 * n; k++) pw[k] = pw[k - 1] * t[i];
      for (let r = 0; r < n; r++) { for (let c = 0; c < n; c++) a[r][c] += pw[r + c]; a[r][n] += pw[r] * d[i]; }
    }
    for (let c = 0; c < n; c++) {
      let p = c; for (let r = c + 1; r < n; r++) if (M.abs(a[r][c]) > M.abs(a[p][c])) p = r;
      [a[c], a[p]] = [a[p], a[c]];
      if (M.abs(a[c][c]) < 1e-14) return new Array(n).fill(0);
      for (let r = 0; r < n; r++) { if (r === c) continue; const f = a[r][c] / a[c][c]; for (let k = c; k <= n; k++) a[r][k] -= f * a[c][k]; }
    }
    return Array.from({ length: n }, (_, i) => a[i][n] / a[i][i]);
  }
  const polyval = (c, t) => { let v = 0; for (let i = c.length - 1; i >= 0; i--) v = v * t + c[i]; return v; };
  function polyfitRobust(t, d, deg = 4) {
    let c = polyfit(t, d, deg), keep = t.map(() => true);
    for (let it = 0; it < 3; it++) {
      const res = t.map((x, i) => M.abs(polyval(c, x) - d[i]));
      const kept = res.filter((_, i) => keep[i]).sort((a, b) => a - b);
      if (!kept.length) break;
      const thr = M.max(kept[kept.length >> 1] * 3, 1e-3), nk = res.map(r => r <= thr);
      const nt = t.filter((_, i) => nk[i]), nd = d.filter((_, i) => nk[i]);
      if (nt.length < deg + 3) break;
      keep = nk; c = polyfit(nt, nd, deg);
    }
    return c;
  }
  const unitOnSide = (s, t, dev) => s === 'top' ? P(t, dev) : s === 'bottom' ? P(t, 1 + dev) : s === 'left' ? P(dev, t) : P(1 + dev, t);
  const unitToSide = (s, uv) => s === 'top' ? [uv.x, uv.y] : s === 'bottom' ? [uv.x, uv.y - 1] : s === 'left' ? [uv.y, uv.x] : [uv.y, uv.x - 1];

  function curvesFromBoundary(bnd, q) {
    const inv = homography(q, UNIT), out = {};
    const ts = {}, ds = {}; SIDES.forEach(s => { ts[s] = []; ds[s] = []; });
    for (const p of bnd) {
      const uv = happly(inv, p.x, p.y);
      for (const s of SIDES) { const [t, d] = unitToSide(s, uv); if (t > 0.03 && t < 0.97 && M.abs(d) < 0.15) { ts[s].push(t); ds[s].push(d); } }
    }
    for (const s of SIDES) out[s] = ts[s].length > 10 ? polyfitRobust(ts[s], ds[s]) : [0, 0, 0, 0, 0];
    return out;
  }
  function probeEdges(g, w, h, q, pred, r, k = 120, t0 = 0.02, t1 = 0.98) {
    const hu = homography(UNIT, q), cen = happly(hu, 0.5, 0.5), steps = M.floor(r);
    const prof = new Float64Array(2 * steps + 1), grad = new Float64Array(2 * steps + 1), out = [];
    for (const s of SIDES) {
      const c = pred[s], profs = [], info = [];
      let flip = 0;
      for (let j = 0; j < k; j++) {
        const t = t0 + (t1 - t0) * j / (k - 1), dev = polyval(c, t);
        const uv = unitOnSide(s, t, dev), uv2 = unitOnSide(s, t, dev + 1e-3);
        const p = happly(hu, uv.x, uv.y), p2 = happly(hu, uv2.x, uv2.y);
        let nx = p2.x - p.x, ny = p2.y - p.y; const nl = M.hypot(nx, ny);
        if (nl < 1e-12) continue; nx /= nl; ny /= nl;
        if (!flip) flip = ((cen.x - p.x) * nx + (cen.y - p.y) * ny) < 0 ? -1 : 1;
        nx *= flip; ny *= flip;
        const pr = new Float64Array(2 * steps + 1);
        for (let o = -steps; o <= steps; o++) pr[o + steps] = sampleG(g, w, h, p.x + nx * o, p.y + ny * o);
        profs.push(pr); info.push({ t, p, nx, ny });
      }
      if (!profs.length) continue;
      const sg = insideSign(profs, steps), found = [];
      for (let j = 0; j < profs.length; j++) {
        const pr = profs[j];
        for (let o = 1; o < pr.length - 1; o++) grad[o] = (pr[o + 1] - pr[o - 1]) / 2;
        const e = pickEdge(pr, grad, sg);
        if (!e) continue;
        const d = e.o - steps, it = info[j];
        found.push({ side: s, t: it.t, p: P(it.p.x + it.nx * d, it.p.y + it.ny * d) });
      }
      if (found.length >= k * 0.4) out.push(...found);
    }
    return out;
  }
  function refineCurves(g, w, h, q, pred, r) {
    const smp = probeEdges(g, w, h, q, pred, r), inv = homography(q, UNIT), res = {};
    for (const s of SIDES) {
      const ts = [], ds = [];
      for (const e of smp) if (e.side === s) { const [t, d] = unitToSide(s, happly(inv, e.p.x, e.p.y)); ts.push(t); ds.push(d); }
      res[s] = ts.length > 12 ? polyfitRobust(ts, ds) : pred[s];
    }
    return res;
  }
  function updateCorners(q, c) {
    const hu = homography(UNIT, q);
    const pts = [P(polyval(c.left, 0), polyval(c.top, 0)), P(1 + polyval(c.right, 0), polyval(c.top, 1)),
      P(1 + polyval(c.right, 1), 1 + polyval(c.bottom, 1)), P(polyval(c.left, 1), 1 + polyval(c.bottom, 0))];
    return quadOrder(pts.map(p => happly(hu, p.x, p.y)));
  }
  function detrend(c) {
    const o = {};
    for (const s of SIDES) { const a = polyval(c[s], 0), b = polyval(c[s], 1), n = c[s].slice(); n[0] -= a; n[1] -= (b - a); o[s] = n; }
    return o;
  }
  function sampleDevs(c) {
    const o = {}; for (const s of SIDES) o[s] = Array.from({ length: NS }, (_, i) => polyval(c[s], i / (NS - 1))); return o;
  }
  function classifyCurl(devs) {
    const endMax = (s, start) => { const d = devs[s]; let m = 0; for (let i = 0; i < 10; i++) m = M.max(m, M.abs(d[start ? i : d.length - 1 - i])); return m; };
    const sc = {
      bottom: M.max(endMax('left', false), endMax('right', false)),
      top: M.max(endMax('left', true), endMax('right', true)),
      left: M.max(endMax('top', true), endMax('bottom', true)),
      right: M.max(endMax('top', false), endMax('bottom', false)),
    };
    let best = 'bottom'; for (const k in sc) if (sc[k] > sc[best]) best = k;
    if (sc[best] < CURL) return [null, false];
    for (const k in sc) if (k !== best && sc[k] > 0.6 * sc[best]) return [best, true];
    return [best, false];
  }

  // Mô hình
  function interpDev(d, t) {
    const f = M.max(0, M.min(1, t)) * (d.length - 1), i = M.min(d.length - 2, M.floor(f)), a = f - i;
    return d[i] + (d[i + 1] - d[i]) * a;
  }
  function makeModel(j) {
    if (!j) return null;
    if (j.type === 'coons') {
      const h = homography(UNIT, j.quad.map(p => P(p.x, p.y)));
      return {
        json: j, aspect: j.aspect,
        map(u, v) {
          const x = u + (1 - u) * interpDev(j.left, v) + u * interpDev(j.right, v);
          const y = v + (1 - v) * interpDev(j.top, u) + v * interpDev(j.bottom, u);
          return happly(h, x, y);
        },
      };
    }
    if (j.type === 'cyl') {
      const z = y => { const d = y - j.y0; return d <= 0 ? 0 : j.c2 * d * d + j.c3 * d * d * d; };
      const m = 400, ys = new Float64Array(m + 1), ss = new Float64Array(m + 1);
      for (let i = 0; i <= m; i++) { ys[i] = j.yMax * i / m; if (i) ss[i] = ss[i - 1] + M.hypot(ys[i] - ys[i - 1], z(ys[i]) - z(ys[i - 1])); }
      const length = ss[m];
      const yFromS = s => {
        if (s <= 0) return 0; if (s >= length) return ys[m];
        let lo = 0, hi = m; while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (ss[mid] < s) lo = mid; else hi = mid; }
        return ys[lo] + (ys[hi] - ys[lo]) * (s - ss[lo]) / (ss[hi] - ss[lo]);
      };
      const canon = (x, s) => {
        const y = yFromS(s), zz = z(y), pt = [0, 1, 2].map(i => j.ptl[i] + x * j.dx[i] + y * j.dy[i] + zz * j.n[i]);
        return P(j.f * pt[0] / pt[2] + j.cx, j.f * pt[1] / pt[2] + j.cy);
      };
      return {
        json: j, length, aspect: j.rot % 2 ? length : 1 / length,
        map(u, v) {
          let cu, cv;
          switch (j.rot % 4) {
            case 0: cu = u; cv = v; break;
            case 1: cu = v; cv = 1 - u; break;
            case 2: cu = 1 - u; cv = 1 - v; break;
            default: cu = 1 - v; cv = u;
          }
          return canon(cu, cv * length);
        },
      };
    }
    return null;
  }

  const CANON = {
    bottom: [['top', 'right', 'bottom', 'left'], [false, false, false, false], 0],
    top: [['bottom', 'left', 'top', 'right'], [true, true, true, true], 2],
    left: [['right', 'bottom', 'left', 'top'], [false, true, false, true], 1],
    right: [['left', 'top', 'right', 'bottom'], [true, false, true, false], 3],
  };
  const cornerIndex = (a, b) => {
    const s = new Set([a, b]);
    if (s.has('top') && s.has('left')) return 0; if (s.has('top') && s.has('right')) return 1;
    if (s.has('right') && s.has('bottom')) return 2; return 3;
  };
  const v3 = {
    dot: (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
    cross: (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]],
    sc: (a, s) => [a[0] * s, a[1] * s, a[2] * s],
    sub: (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]],
    add: (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]],
    norm: a => { const l = M.hypot(a[0], a[1], a[2]); return l < 1e-15 ? a : [a[0] / l, a[1] / l, a[2] / l]; },
  };
  function lineH(pts) {
    if (pts.length < 3) return null;
    const l = fitLine(pts); const nx = -l.d.y, ny = l.d.x;
    return [nx, ny, -(nx * l.c.x + ny * l.c.y)];
  }
  function buildCylinder(samples, curl, corners, focal, W, H, flatUntil = 0.55) {
    const [names, rev, rot] = CANON[curl];
    const sideOf = idx => samples.filter(e => e.side === names[idx]).map(e => [rev[idx] ? 1 - e.t : e.t, e.p]);
    const top = sideOf(0), right = sideOf(1), left = sideOf(3);
    if (top.length < 20 || right.length < 20 || left.length < 20) return null;
    const lt = lineH(top.map(e => e[1])), ll = lineH(left.filter(e => e[0] < flatUntil).map(e => e[1])), lr = lineH(right.filter(e => e[0] < flatUntil).map(e => e[1]));
    if (!lt || !ll || !lr) return null;
    const cx = W / 2, cy = H / 2, kinv = p => [(p[0] - cx * p[2]) / focal, (p[1] - cy * p[2]) / focal, p[2]];
    let tl = v3.cross(lt, ll), tr = v3.cross(lt, lr); const vy = v3.cross(ll, lr);
    if (M.abs(tl[2]) < 1e-12 || M.abs(tr[2]) < 1e-12) return null;
    tl = v3.sc(tl, 1 / tl[2]); tr = v3.sc(tr, 1 / tr[2]);
    const ktl = kinv(tl), ktr = kinv(tr), kvy = kinv(vy);
    const a = v3.dot(ktr, kvy), b = -v3.dot(ktl, kvy);
    let dX = v3.norm(v3.add(v3.sc(ktl, a), v3.sc(ktr, b))), dY = v3.norm(kvy);
    if (v3.dot(dX, v3.sub(v3.sc(ktr, 1 / ktr[2]), v3.sc(ktl, 1 / ktl[2]))) < 0) dX = v3.sc(dX, -1);
    const a11 = v3.dot(ktl, ktl), a12 = -v3.dot(ktl, ktr), a22 = v3.dot(ktr, ktr), b1 = -v3.dot(ktl, dX), b2 = v3.dot(ktr, dX);
    const det = a11 * a22 - a12 * a12; if (M.abs(det) < 1e-15) return null;
    const ptl = v3.sc(ktl, (b1 * a22 - a12 * b2) / det); if (ptl[2] <= 0) return null;
    const mid = left[left.length >> 1][1], rl = kinv([mid.x, mid.y, 1]), d0 = v3.dot(rl, dX);
    if (M.abs(d0) > 1e-12) { const lam = v3.dot(ptl, dX) / d0; if (v3.dot(v3.sub(v3.sc(rl, lam), ptl), dY) < 0) dY = v3.sc(dY, -1); }
    dY = v3.norm(v3.sub(dY, v3.sc(dX, v3.dot(dY, dX))));
    const n = v3.cross(dX, dY);
    const back = (p, x0) => {
      const r = kinv([p.x, p.y, 1]), den = v3.dot(r, dX); if (M.abs(den) < 1e-12) return null;
      const q = v3.sub(v3.sc(r, (v3.dot(ptl, dX) + x0) / den), ptl); return [v3.dot(q, dY), v3.dot(q, n)];
    };
    const ys = [], zs = [];
    for (const e of left) { const r = back(e[1], 0); if (r) { ys.push(r[0]); zs.push(r[1]); } }
    for (const e of right) { const r = back(e[1], 1); if (r) { ys.push(r[0]); zs.push(r[1]); } }
    const bl = corners[cornerIndex(names[2], names[3])], br = corners[cornerIndex(names[1], names[2])];
    // Điểm kết thúc trang: lấy góc GẦN hơn trong 2 góc đầu quăn (góc kia có thể bị
    // dò lố ra nền/bóng) → không để lại dải nền ở mép trang.
    const ends = [];
    for (const [c, x0] of [[bl, 0], [br, 1]]) { const r = back(c, x0); if (r) { ys.push(r[0]); zs.push(r[1]); ends.push(r[0]); } }
    const yEnd = ends.length ? M.min(...ends) : 0;
    if (ys.length < 30 || yEnd <= 0) return null;
    const yMax = yEnd;
    const flat = zs.filter((_, i) => ys[i] < yMax * 0.4).sort((a, b) => a - b);
    const fz = flat.length ? flat[flat.length >> 1] : 0;
    for (let i = 0; i < zs.length; i++) zs[i] -= fz;
    let best = [Infinity, 0, 0, yMax]; const cap = 0.004 * 0.004;
    for (let k = 0; k < 68; k++) {
      const y0 = yMax * (0.3 + 0.67 * k / 67);
      let s22 = 0, s23 = 0, s33 = 0, sz2 = 0, sz3 = 0, cnt = 0;
      for (let i = 0; i < ys.length; i++) {
        const d = ys[i] - y0; if (d <= 0) continue;
        const d2 = d * d, d3 = d2 * d; s22 += d2 * d2; s23 += d2 * d3; s33 += d3 * d3; sz2 += d2 * zs[i]; sz3 += d3 * zs[i]; cnt++;
      }
      if (cnt < 8) continue;
      const dd = s22 * s33 - s23 * s23; if (M.abs(dd) < 1e-30) continue;
      const c2 = (sz2 * s33 - s23 * sz3) / dd, c3 = (s22 * sz3 - s23 * sz2) / dd;
      let sse = 0;
      for (let i = 0; i < ys.length; i++) { const d = ys[i] - y0, pr = d <= 0 ? 0 : c2 * d * d + c3 * d * d * d; sse += M.min((pr - zs[i]) ** 2, cap); }
      if (sse < best[0]) best = [sse, c2, c3, y0];
    }
    if (best[0] === Infinity) return null;
    const j = { type: 'cyl', f: focal, cx, cy, ptl, dx: dX, dy: dY, n, y0: best[3], c2: best[1], c3: best[2], yMax, rot };
    const mdl = makeModel(j);
    if (!isFinite(mdl.length) || mdl.length < 0.3 || mdl.length > 4) return null;
    return j;
  }

  function analyzeCurvature(g, w, h, q, boundary, focal) {
    const r = M.max(6, 0.012 * M.hypot(w, h));
    let quad = q;
    let pred = boundary.length > 40 ? detrend(curvesFromBoundary(boundary, quad)) : { top: [0, 0, 0, 0, 0], right: [0, 0, 0, 0, 0], bottom: [0, 0, 0, 0, 0], left: [0, 0, 0, 0, 0] };
    for (let it = 0; it < 3; it++) {
      const c = refineCurves(g, w, h, quad, pred, r), nq = updateCorners(quad, c);
      if (!isConvex(nq) || quadArea(nq) < 0.5 * quadArea(quad)) break;
      quad = nq; pred = detrend(c);
    }
    const fin = detrend(refineCurves(g, w, h, quad, pred, r)), devs = sampleDevs(fin);
    let curv = 0; for (const s of SIDES) for (const v of devs[s]) curv = M.max(curv, M.abs(v));
    if (curv < CURL) return { corners: q, model: null, curvature: curv, kind: 'flat' };
    const [side, complex] = classifyCurl(devs);
    if (side && !complex) {
      const smp = probeEdges(g, w, h, quad, fin, r, 160, 0.01, 0.99);
      const cyl = buildCylinder(smp, side, quad, focal, w, h);
      if (cyl) return { corners: quad, model: cyl, curvature: curv, kind: 'curl' };
    }
    const aspect = estimateAspect(quad, w, h, focal, 'free').ratio;
    return { corners: quad, model: Object.assign({ type: 'coons', quad, aspect }, devs), curvature: curv, kind: 'complex' };
  }

  // -------------------------------------------------------------- nắn ảnh
  const WX = new Float64Array(4), WY = new Float64Array(4);
  function cubicW(t, w) { const t2 = t * t, t3 = t2 * t; w[0] = -0.5 * t3 + t2 - 0.5 * t; w[1] = 1.5 * t3 - 2.5 * t2 + 1; w[2] = -1.5 * t3 + 2 * t2 + 0.5 * t; w[3] = 0.5 * t3 - 0.5 * t2; }
  /** Lấy mẫu RGBA tại (sx,sy) ghi vào out[o..o+3]. */
  function sampleInto(src, sw, sh, sx, sy, out, o, bicubic) {
    const mx = sw - 1, my = sh - 1;
    if (sx < 0) sx = 0; if (sy < 0) sy = 0; if (sx > mx) sx = mx; if (sy > my) sy = my;
    const x0 = sx | 0, y0 = sy | 0, x1 = x0 < mx ? x0 + 1 : x0, y1 = y0 < my ? y0 + 1 : y0, fx = sx - x0, fy = sy - y0;
    const i00 = (y0 * sw + x0) * 4, i10 = (y0 * sw + x1) * 4, i01 = (y1 * sw + x0) * 4, i11 = (y1 * sw + x1) * 4;
    if (bicubic) {
      cubicW(fx, WX); cubicW(fy, WY);
      for (let c = 0; c < 3; c++) {
        let acc = 0;
        for (let m = -1; m <= 2; m++) {
          const yy = M.min(my, M.max(0, y0 + m)); let row = 0;
          for (let n = -1; n <= 2; n++) row += src[(yy * sw + M.min(mx, M.max(0, x0 + n))) * 4 + c] * WX[n + 1];
          acc += row * WY[m + 1];
        }
        const a = src[i00 + c], b = src[i10 + c], d = src[i01 + c], e = src[i11 + c];
        const lo = M.min(a, b, d, e), hi = M.max(a, b, d, e);
        out[o + c] = acc < lo ? lo : acc > hi ? hi : acc;
      }
    } else {
      for (let c = 0; c < 3; c++) {
        const top = src[i00 + c] + (src[i10 + c] - src[i00 + c]) * fx, bot = src[i01 + c] + (src[i11 + c] - src[i01 + c]) * fx;
        out[o + c] = top + (bot - top) * fy;
      }
    }
    out[o + 3] = 255;
  }
  function warpQuad(src, sw, sh, q, ow, oh, bicubic) {
    const out = new Uint8ClampedArray(ow * oh * 4);
    const h = homography([P(0, 0), P(ow - 1, 0), P(ow - 1, oh - 1), P(0, oh - 1)], q);
    let o = 0;
    for (let y = 0; y < oh; y++) for (let x = 0; x < ow; x++, o += 4) {
      const w = h[6] * x + h[7] * y + h[8];
      sampleInto(src, sw, sh, (h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w, out, o, bicubic);
    }
    return out;
  }
  function warpModel(src, sw, sh, model, scale, ow, oh, bicubic) {
    const out = new Uint8ClampedArray(ow * oh * 4); let o = 0;
    for (let y = 0; y < oh; y++) {
      const v = (y + 0.5) / oh;
      for (let x = 0; x < ow; x++, o += 4) {
        const p = model.map((x + 0.5) / ow, v);
        sampleInto(src, sw, sh, p.x * scale - 0.5, p.y * scale - 0.5, out, o, bicubic);
      }
    }
    return out;
  }
  function rotate90(src, w, h, q) {
    q = ((q % 4) + 4) % 4; if (!q) return [src, w, h];
    const nw = q % 2 ? h : w, nh = q % 2 ? w : h, out = new Uint8ClampedArray(src.length);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let dx, dy;
      if (q === 1) { dx = h - 1 - y; dy = x; } else if (q === 2) { dx = w - 1 - x; dy = h - 1 - y; } else { dx = y; dy = w - 1 - x; }
      const si = (y * w + x) * 4, di = (dy * nw + dx) * 4;
      out[di] = src[si]; out[di + 1] = src[si + 1]; out[di + 2] = src[si + 2]; out[di + 3] = 255;
    }
    return [out, nw, nh];
  }
  function rotateFine(src, w, h, deg) {
    const t = deg * M.PI / 180, c = M.cos(t), s = M.sin(t), cx = (w - 1) / 2, cy = (h - 1) / 2;
    const out = new Uint8ClampedArray(src.length); let o = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++, o += 4) {
      const dx = x - cx, dy = y - cy, sx = c * dx + s * dy + cx, sy = -s * dx + c * dy + cy;
      if (sx < 0 || sy < 0 || sx > w - 1 || sy > h - 1) { out[o] = out[o + 1] = out[o + 2] = out[o + 3] = 255; continue; }
      sampleInto(src, w, h, sx, sy, out, o, false);
    }
    return out;
  }
  function estimateSkew(gray, w, h) {
    const d = downGray(gray, w, h, 1000), g = d.g, sw = d.w, sh = d.h;
    const I = new Float64Array((sw + 1) * (sh + 1));
    for (let y = 0; y < sh; y++) { let row = 0; for (let x = 0; x < sw; x++) { row += g[y * sw + x]; I[(y + 1) * (sw + 1) + x + 1] = I[y * (sw + 1) + x + 1] + row; } }
    const xs = [], ys = [], r = 15;
    for (let y = 0; y < sh; y++) {
      const y0 = M.max(0, y - r), y1 = M.min(sh, y + r + 1);
      for (let x = 0; x < sw; x++) {
        const x0 = M.max(0, x - r), x1 = M.min(sw, x + r + 1);
        const sum = I[y1 * (sw + 1) + x1] - I[y0 * (sw + 1) + x1] - I[y1 * (sw + 1) + x0] + I[y0 * (sw + 1) + x0];
        if (g[y * sw + x] < sum / ((x1 - x0) * (y1 - y0)) * 0.75) { xs.push(x - sw / 2); ys.push(y - sh / 2); }
      }
    }
    if (xs.length < 200) return { angle: 0, gain: 1, reliable: false, correction: 0 };
    const stride = M.ceil(xs.length / 40000);
    const score = deg => {
      const t = deg * M.PI / 180, c = M.cos(t), s = M.sin(t), bins = new Map();
      for (let i = 0; i < xs.length; i += stride) { const k = M.floor(ys[i] * c - xs[i] * s); bins.set(k, (bins.get(k) || 0) + 1); }
      let acc = 0; for (const v of bins.values()) acc += v * v; return acc;
    };
    let best = 0, bs = -1;
    for (let a = -15; a <= 15.0001; a += 0.5) { const v = score(a); if (v > bs) { bs = v; best = a; } }
    const c0 = best;
    for (let a = c0 - 0.5; a <= c0 + 0.5001; a += 0.05) { const v = score(a); if (v > bs) { bs = v; best = a; } }
    const gain = bs / M.max(1, score(0));
    const reliable = gain >= 1.15 && M.abs(best) >= 0.15 && M.abs(best) < 14.9;
    return { angle: best, gain, reliable, correction: -best };
  }

  // ------------------------------------------------------------ làm sáng
  /** Mô hình nền giấy. fine=true (Xoá bóng): lưới mịn hơn + lọc trung vị giữ mép bóng cứng
   *  (bóng tay/điện thoại dưới đèn) thay vì làm nhoè thành viền. */
  function bgModel(rgba, w, h, fine) {
    const block = M.max(2, M.ceil(M.max(w, h) / (fine ? 220 : 96))), gw = M.ceil(w / block), gh = M.ceil(h / block);
    const grid = new Float64Array(gw * gh * 3), valid = new Uint8Array(gw * gh);
    const hist = [new Int32Array(256), new Int32Array(256), new Int32Array(256)];
    for (let by = 0; by < gh; by++) for (let bx = 0; bx < gw; bx++) {
      const x0 = bx * block, y0 = by * block, x1 = M.min(w, x0 + block), y1 = M.min(h, y0 + block);
      hist[0].fill(0); hist[1].fill(0); hist[2].fill(0);
      let cand = 0; const total = (x1 - x0) * (y1 - y0);
      for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
        const i = (y * w + x) * 4, r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        const mx = r > g ? (r > b ? r : b) : (g > b ? g : b), mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
        if (mx - mn <= 0.3 * mx + 12) { hist[0][r]++; hist[1][g]++; hist[2][b]++; cand++; }
      }
      if (cand < total * 0.15 || !cand) continue;
      const k = by * gw + bx; valid[k] = 1;
      for (let c = 0; c < 3; c++) { let acc = 0, v = 255; for (let t = 255; t >= 0; t--) { acc += hist[c][t]; if (acc >= cand * 0.1) { v = t; break; } } grid[k * 3 + c] = v; }
    }
    const L = k => grid[k * 3] * 0.299 + grid[k * 3 + 1] * 0.587 + grid[k * 3 + 2] * 0.114;
    const lums = []; for (let k = 0; k < gw * gh; k++) if (valid[k]) lums.push(L(k));
    if (!lums.length) { grid.fill(255); return { gw, gh, grid, level: [255, 255, 255], uneven: 1 }; }
    lums.sort((a, b) => a - b);
    const paper = lums[M.min(lums.length - 1, M.floor(lums.length * 0.9))];
    for (let k = 0; k < gw * gh; k++) if (valid[k] && L(k) < paper * 0.35) valid[k] = 0;
    let missing = 0; for (const v of valid) if (!v) missing++;
    for (let guard = gw + gh + 2; missing > 0 && guard > 0; guard--) {
      const next = valid.slice();
      for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) {
        const k = y * gw + x; if (valid[k]) continue;
        let n = 0; const s = [0, 0, 0];
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
          const xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= gw || yy >= gh) continue;
          const kk = yy * gw + xx; if (!valid[kk]) continue; n++; for (let c = 0; c < 3; c++) s[c] += grid[kk * 3 + c];
        }
        if (n) { for (let c = 0; c < 3; c++) grid[k * 3 + c] = s[c] / n; next[k] = 1; missing--; }
      }
      valid.set(next);
    }
    const blur = gsrc => {
      const o = new Float64Array(gsrc.length);
      for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) for (let c = 0; c < 3; c++) {
        let s = 0, n = 0;
        for (let dy = -2; dy <= 2; dy++) { const yy = M.min(gh - 1, M.max(0, y + dy)); for (let dx = -2; dx <= 2; dx++) { const xx = M.min(gw - 1, M.max(0, x + dx)); s += gsrc[(yy * gw + xx) * 3 + c]; n++; } }
        o[(y * gw + x) * 3 + c] = s / n;
      }
      return o;
    };
    const median3 = (gsrc) => {
      const o = new Float64Array(gsrc.length), v = new Float64Array(9);
      for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) for (let c = 0; c < 3; c++) {
        let n = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
          const yy = M.min(gh - 1, M.max(0, y + dy)), xx = M.min(gw - 1, M.max(0, x + dx)); v[n++] = gsrc[(yy * gw + xx) * 3 + c];
        }
        o[(y * gw + x) * 3 + c] = v.sort()[4];
      }
      return o;
    };
    const blur3 = (gsrc) => {
      const o = new Float64Array(gsrc.length);
      for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) for (let c = 0; c < 3; c++) {
        let s = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) s += gsrc[(M.min(gh - 1, M.max(0, y + dy)) * gw + M.min(gw - 1, M.max(0, x + dx))) * 3 + c];
        o[(y * gw + x) * 3 + c] = s / 9;
      }
      return o;
    };
    const sm = fine ? blur3(median3(median3(grid))) : blur(blur(grid)), level = [255, 255, 255];
    for (let c = 0; c < 3; c++) {
      const vals = []; for (let i = c; i < sm.length; i += 3) vals.push(sm[i]); vals.sort((a, b) => a - b);
      level[c] = M.max(1, vals[M.min(vals.length - 1, M.floor(vals.length * 0.9))]);
      for (let i = c; i < sm.length; i += 3) if (sm[i] < level[c] * 0.3) sm[i] = level[c] * 0.3;
    }
    let mn = Infinity, mxl = 0;
    for (let i = 0; i < sm.length; i += 3) { const l = sm[i] * 0.299 + sm[i + 1] * 0.587 + sm[i + 2] * 0.114; mn = M.min(mn, l); mxl = M.max(mxl, l); }
    return { gw, gh, grid: sm, level, uneven: mxl ? mn / mxl : 1 };
  }
  /** Lọc max/min 1 chiều (van Herk – Gil-Werman, O(1)/điểm) trên mặt phẳng float. */
  function vhg(src, w, h, r, isMax, horizontal) {
    const out = new Float32Array(src.length), k = 2 * r + 1;
    const n = horizontal ? w : h, lines = horizontal ? h : w;
    const g = new Float32Array(n + k), hh = new Float32Array(n + k), buf = new Float32Array(n + 2 * r);
    const pick = isMax ? (a, b) => (a > b ? a : b) : (a, b) => (a < b ? a : b);
    for (let L = 0; L < lines; L++) {
      const at = (i) => horizontal ? L * w + i : i * w + L;
      for (let i = 0; i < n + 2 * r; i++) { const j = M.min(n - 1, M.max(0, i - r)); buf[i] = src[at(j)]; }
      const m = n + 2 * r;
      for (let i = 0; i < m; i++) g[i] = i % k === 0 ? buf[i] : pick(g[i - 1], buf[i]);
      for (let i = m - 1; i >= 0; i--) hh[i] = (i % k === k - 1 || i === m - 1) ? buf[i] : pick(hh[i + 1], buf[i]);
      for (let i = 0; i < n; i++) out[at(i)] = pick(hh[i], g[i + k - 1]);
    }
    return out;
  }
  /** Nền giấy chi tiết theo từng điểm ảnh cho chế độ Xoá bóng:
   *  phép đóng (max rồi min, bán kính r) xoá nét chữ ≤ 2r khỏi bản đồ nền nhưng GIỮ mép bóng
   *  đúng vị trí; kẹp theo mô hình thô để vùng nội dung lớn (ô đen, ảnh) không bị coi là nền. */
  function bgPixel(rgba, w, h, coarse, gate) {
    const f = M.max(1, M.round(M.max(w, h) / 1200)), sw = M.ceil(w / f), sh = M.ceil(h / f);
    const r = M.max(3, M.round(M.max(w, h) / 250 / f));
    const planes = [0, 1, 2].map(() => new Float32Array(sw * sh));
    for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) {
      let a = 0, b = 0, c = 0, n = 0;
      for (let dy = 0; dy < f; dy++) for (let dx = 0; dx < f; dx++) {
        const X = M.min(w - 1, x * f + dx), Y = M.min(h - 1, y * f + dy), i = (Y * w + X) * 4; a += rgba[i]; b += rgba[i + 1]; c += rgba[i + 2]; n++;
      }
      const k = y * sw + x; planes[0][k] = a / n; planes[1][k] = b / n; planes[2][k] = c / n;
    }
    const closed = planes.map((pl) => vhg(vhg(vhg(vhg(pl, sw, sh, r, true, true), sw, sh, r, true, false), sw, sh, r, false, true), sw, sh, r, false, false));
    const paperL = coarse.level[0] * 0.299 + coarse.level[1] * 0.587 + coarse.level[2] * 0.114, tmp = [0, 0, 0], tg = [0, 0, 0];
    // Bản đồ "có bóng gần đây": độ tối của mô hình thô so với giấy, nới rộng 2 ô rồi làm mượt.
    const gw = gate.gw, gh = gate.gh, dark = new Float32Array(gw * gh), gL = gate.level[0] * 0.299 + gate.level[1] * 0.587 + gate.level[2] * 0.114;
    for (let k = 0; k < gw * gh; k++) { const L = gate.grid[k * 3] * 0.299 + gate.grid[k * 3 + 1] * 0.587 + gate.grid[k * 3 + 2] * 0.114; dark[k] = M.max(0, 1 - L / gL); }
    // phép mở (min rồi max) bán kính ~4% trang: bỏ các ô xám/khung nhỏ là NỘI DUNG, chỉ giữ vùng bóng lớn
    const ro = M.max(2, M.round(M.max(gw, gh) * 0.045));
    const opened = vhg(vhg(vhg(vhg(dark, gw, gh, ro, false, true), gw, gh, ro, false, false), gw, gh, ro, true, true), gw, gh, ro, true, false);
    let dil = vhg(vhg(opened, gw, gh, 2, true, true), gw, gh, 2, true, false);
    const gb = new Float32Array(gw * gh);
    for (let y = 0; y < gh; y++) for (let x = 0; x < gw; x++) { let a = 0, n = 0;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const xx = x + dx, yy = y + dy; if (xx < 0 || yy < 0 || xx >= gw || yy >= gh) continue; a += dil[yy * gw + xx]; n++; }
      gb[y * gw + x] = a / n; }
    const gateAt = (X, Y) => { const v = gb[M.min(gh - 1, (Y / h * gh) | 0) * gw + M.min(gw - 1, (X / w * gw) | 0)]; return M.max(0, M.min(1, (v - 0.05) / 0.08)); };
    const outp = [0, 1, 2].map(() => new Float32Array(sw * sh));
    for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) {
      const k = y * sw + x;
      const X = M.min(w - 1, x * f + (f >> 1)), Y = M.min(h - 1, y * f + (f >> 1));
      bgSample(coarse, X, Y, w, h, tmp); bgSample(gate, X, Y, w, h, tg);
      const c0 = closed[0][k], c1 = closed[1][k], c2 = closed[2][k], L = 0.299 * c0 + 0.587 * c1 + 0.114 * c2;
      // màu nền chi tiết phải trung tính & cùng sắc độ với giấy (bóng đèn chỉ làm tối, không đổi màu)
      const mx = M.max(c0, c1, c2), mn = M.min(c0, c1, c2), sC = c0 + c1 + c2 + 1e-3, sT = tmp[0] + tmp[1] + tmp[2] + 1e-3;
      const chroma = M.max(M.abs(c0 / sC - tmp[0] / sT), M.abs(c1 / sC - tmp[1] / sT), M.abs(c2 / sC - tmp[2] / sT));
      let wgt = gateAt(X, Y);
      if (L < 0.35 * paperL || mx - mn > 0.3 * mx + 12) wgt = 0;
      else wgt *= M.max(0, M.min(1, (0.06 - chroma) / 0.03));
      for (let c = 0; c < 3; c++) {
        const v = M.max(0.6 * tmp[c], M.min(1.6 * tmp[c], closed[c][k]));
        outp[c][k] = M.max(1, wgt * v + (1 - wgt) * tg[c]);
      }
    }
    // làm mượt nhẹ 3×3 để giảm nhiễu
    const sm = outp.map((pl) => { const o = new Float32Array(pl.length);
      for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) { let s2 = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) s2 += pl[M.min(sh - 1, M.max(0, y + dy)) * sw + M.min(sw - 1, M.max(0, x + dx))];
        o[y * sw + x] = s2 / 9; } return o; });
    return { f, sw, sh, planes: sm, level: coarse.level };
  }
  function bgPixelSample(bp, x, y, out) {
    if (bp.f === 1) { const k = y * bp.sw + x; out[0] = bp.planes[0][k]; out[1] = bp.planes[1][k]; out[2] = bp.planes[2][k]; return; }
    const fx = M.min(bp.sw - 1, M.max(0, (x + 0.5) / bp.f - 0.5)), fy = M.min(bp.sh - 1, M.max(0, (y + 0.5) / bp.f - 0.5));
    const x0 = fx | 0, y0 = fy | 0, x1 = M.min(bp.sw - 1, x0 + 1), y1 = M.min(bp.sh - 1, y0 + 1), ax = fx - x0, ay = fy - y0;
    for (let c = 0; c < 3; c++) { const p = bp.planes[c];
      const t = p[y0 * bp.sw + x0] + (p[y0 * bp.sw + x1] - p[y0 * bp.sw + x0]) * ax, b = p[y1 * bp.sw + x0] + (p[y1 * bp.sw + x1] - p[y1 * bp.sw + x0]) * ax;
      out[c] = t + (b - t) * ay; }
  }
  function bgSample(bg, x, y, w, h, out) {
    const fx = M.max(0, M.min(bg.gw - 1, (x + 0.5) / w * bg.gw - 0.5)), fy = M.max(0, M.min(bg.gh - 1, (y + 0.5) / h * bg.gh - 0.5));
    const x0 = fx | 0, y0 = fy | 0, x1 = M.min(bg.gw - 1, x0 + 1), y1 = M.min(bg.gh - 1, y0 + 1), ax = fx - x0, ay = fy - y0, d = bg.grid;
    for (let c = 0; c < 3; c++) {
      const a = d[(y0 * bg.gw + x0) * 3 + c], b = d[(y0 * bg.gw + x1) * 3 + c], e = d[(y1 * bg.gw + x0) * 3 + c], f = d[(y1 * bg.gw + x1) * 3 + c];
      const t = a + (b - a) * ax, bo = e + (f - e) * ax; out[c] = M.max(1, t + (bo - t) * ay);
    }
  }
  /** Tăng cường tài liệu. p.mode: original | document | bw | gray. */
  function enhance(rgba, w, h, p) {
    let out = new Uint8ClampedArray(rgba.length);
    // light (Làm sáng): giữ màu gốc nhưng đưa nền về trắng một phần
    const whiten = p.mode !== 'original' && p.mode !== 'light';
    const s = whiten || p.mode === 'light' || p.deshadow ? 1 : M.max(0, M.min(1, p.shadow ?? 0.7));
    const tmp = [0, 0, 0];
    if (whiten || s > 0.01) {
      const bg = bgModel(rgba, w, h, false), T = 250;
      const bp = p.deshadow ? bgPixel(rgba, w, h, bgModel(rgba, w, h, true), bg) : null;
      if (p.mode === 'light') bg.level = bg.level.map((v) => v + (250 - v) * 0.75);
      const sampleBg = bp ? (x, y, o) => bgPixelSample(bp, x, y, o) : (x, y, o) => bgSample(bg, x, y, w, h, o);
      let white = 255, black = 0;
      if (whiten) {
        const hist = new Int32Array(512); let n = 0;
        for (let i = 0; i < w * h; i += 5) {
          sampleBg(i % w, (i / w) | 0, tmp); const j = i * 4;
          const l = 0.299 * rgba[j] * T / tmp[0] + 0.587 * rgba[j + 1] * T / tmp[1] + 0.114 * rgba[j + 2] * T / tmp[2];
          hist[M.min(511, M.max(0, M.round(l)))]++; n++;
        }
        const pct = q => { let acc = 0; for (let v = 0; v < 512; v++) { acc += hist[v]; if (acc >= n * q) return v; } return 511; };
        white = M.max(120, pct(0.6) * 0.98); black = M.min(pct(0.005), white * 0.4);
      }
      const gain = 255 / M.max(1, white - black);
      let o = 0;
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++, o += 4) {
        sampleBg(x, y, tmp);
        for (let c = 0; c < 3; c++) {
          const v = rgba[o + c], ref = whiten ? T : bg.level[c];
          let nv = v * ref / tmp[c]; if (whiten) nv = (nv - black) * gain;
          out[o + c] = v + (nv - v) * s;
        }
        out[o + 3] = 255;
      }
    } else out.set(rgba);
    if (p.mode === 'magic') {
      // Magic Color: nền trắng + màu mực/dấu/chữ ký tươi hơn (tăng bão hoà quanh xám, không đổi độ sáng)
      for (let i = 0; i < out.length; i += 4) {
        const r = out[i], g = out[i + 1], b = out[i + 2], l = 0.299 * r + 0.587 * g + 0.114 * b;
        out[i] = l + (r - l) * 1.45; out[i + 1] = l + (g - l) * 1.45; out[i + 2] = l + (b - l) * 1.45;
      }
    }
    if (p.mode === 'gray' || p.mode === 'bw') {
      for (let i = 0; i < out.length; i += 4) { const l = (out[i] * 299 + out[i + 1] * 587 + out[i + 2] * 114) / 1000; out[i] = out[i + 1] = out[i + 2] = l; }
    }
    if (p.mode === 'bw') out = sauvola(out, w, h);
    const br = p.brightness || 0, ct = p.contrast || 0, wm = p.warmth || 0;
    if (M.abs(br) > 1e-3 || M.abs(ct) > 1e-3 || M.abs(wm) > 1e-3) {
      const luts = [0, 1, 2].map(c => {
        const lut = new Uint8ClampedArray(256), wb = c === 0 ? wm * 18 : c === 2 ? -wm * 18 : 0;
        for (let v = 0; v < 256; v++) lut[v] = ((v + br * 60 + wb) - 128) * (1 + ct) + 128;
        return lut;
      });
      for (let i = 0; i < out.length; i += 4) { out[i] = luts[0][out[i]]; out[i + 1] = luts[1][out[i + 1]]; out[i + 2] = luts[2][out[i + 2]]; }
    }
    const sharp = M.max(p.sharpness || 0, p.mode === 'magic' ? 0.35 : 0);
    if (sharp > 0.01 && p.mode !== 'bw') out = unsharp(out, w, h, sharp);
    return out;
  }
  function sauvola(g4, w, h) {
    const I = new Float64Array((w + 1) * (h + 1)), I2 = new Float64Array((w + 1) * (h + 1));
    for (let y = 0; y < h; y++) {
      let rs = 0, rq = 0;
      for (let x = 0; x < w; x++) { const v = g4[(y * w + x) * 4]; rs += v; rq += v * v; const k = (y + 1) * (w + 1) + x + 1; I[k] = I[k - w - 1] + rs; I2[k] = I2[k - w - 1] + rq; }
    }
    const r = M.max(7, (M.min(w, h) / 60) | 0), out = new Uint8ClampedArray(g4.length);
    for (let y = 0; y < h; y++) {
      const y0 = M.max(0, y - r), y1 = M.min(h, y + r + 1);
      for (let x = 0; x < w; x++) {
        const x0 = M.max(0, x - r), x1 = M.min(w, x + r + 1);
        const a = y0 * (w + 1) + x0, b = y0 * (w + 1) + x1, c = y1 * (w + 1) + x0, d = y1 * (w + 1) + x1, n = (x1 - x0) * (y1 - y0);
        const mean = (I[d] - I[b] - I[c] + I[a]) / n, sq = (I2[d] - I2[b] - I2[c] + I2[a]) / n;
        const t = mean * (1 + 0.15 * (M.sqrt(M.max(0, sq - mean * mean)) / 128 - 1));
        const i = (y * w + x) * 4, v = g4[i] > t ? 255 : 0;
        out[i] = out[i + 1] = out[i + 2] = v; out[i + 3] = 255;
      }
    }
    return out;
  }
  function unsharp(src, w, h, amount) {
    const a = M.min(1, amount) * 0.8, out = new Uint8ClampedArray(src.length);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) for (let c = 0; c < 4; c++) {
      const i = (y * w + x) * 4 + c;
      if (c === 3 || !x || !y || x === w - 1 || y === h - 1) { out[i] = src[i]; continue; }
      let s = 0; for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) s += src[((y + dy) * w + x + dx) * 4 + c];
      out[i] = src[i] + M.max(-36, M.min(36, (src[i] - s / 9) * a));
    }
    return out;
  }

  // ------------------------------------------------------------ chất lượng
  function quality(fullW, fullH, smallGray, sw, sh, det, rgbaSmall) {
    const issues = [], lv = lapVar(smallGray, sw, sh);
    if (lv < 35) issues.push({ code: 'blur', sev: lv < 17 ? 2 : 1, msg: `Ảnh có thể bị mờ hoặc rung tay (độ nét ${lv | 0}). Nên chụp lại.` });
    let sum = 0, clip = 0; for (const v of smallGray) { sum += v; if (v >= 254) clip++; }
    const mean = sum / smallGray.length;
    if (mean < 70) issues.push({ code: 'dark', sev: mean < 35 ? 2 : 1, msg: 'Ảnh thiếu sáng. Hãy bật đèn rồi chụp lại.' });
    if (clip / smallGray.length > 0.22) issues.push({ code: 'overexposed', sev: 1, msg: 'Có vùng cháy sáng – chi tiết vùng đó không khôi phục được. Nên đổi góc, tránh phản chiếu.' });
    if (rgbaSmall && bgModel(rgbaSmall, sw, sh).uneven < 0.55) issues.push({ code: 'shadow', sev: 0, msg: 'Có bóng đổ – đã tự cân bằng sáng.' });
    if (M.max(fullW, fullH) < 1600) issues.push({ code: 'low_res', sev: 1, msg: `Độ phân giải thấp (${fullW}×${fullH}). Chữ nhỏ có thể không rõ.` });
    if (!det.quad) issues.push({ code: 'no_document', sev: 1, msg: 'Không nhận diện chắc chắn tài liệu – hãy chỉnh 4 góc bằng tay.' });
    else {
      if (det.issues.includes('corner_out_of_frame')) issues.push({ code: 'corner_cut', sev: 1, msg: 'Có góc tài liệu nằm ngoài khung hình.' });
      if (det.issues.includes('occluded')) issues.push({ code: 'occluded', sev: 1, msg: 'Tài liệu có thể bị che một phần.' });
      if (det.fill < 0.25) issues.push({ code: 'small_doc', sev: 1, msg: 'Tài liệu nhỏ trong khung – nên đưa máy lại gần.' });
    }
    return issues;
  }

  // -------------------------------------------------------- điểm vào cao cấp
  /** Phân tích ảnh vừa chụp: góc (đã tinh chỉnh), mô hình cong, chất lượng. */
  function analyze(rgba, w, h, f35) {
    const gray = toGray(rgba, w, h), sm = downGray(gray, w, h, 720);
    const det = detect(sm.g, sm.w, sm.h), sc = 1 / sm.s;
    let corners = null, model = null, kind = 'flat', curvature = 0, fine = 0;
    const focal = f35 ? focalFrom35(f35, w, h) : defaultFocal(w, h);
    if (det.quad) corners = refineQuad(gray, w, h, scaleQuad(det.quad, sc).map(p => P(M.max(0, M.min(w, p.x)), M.max(0, M.min(h, p.y))))).quad;
    const reliable = det.reliable && corners;
    if (reliable) {
      try {
        const c = analyzeCurvature(gray, w, h, corners, det.boundary.map(p => P(p.x * sc, p.y * sc)), focal);
        corners = c.corners; model = c.model; kind = c.kind; curvature = c.curvature;
      } catch (e) { model = null; }
    } else {
      const sk = estimateSkew(gray, w, h); if (sk.reliable) fine = sk.correction;
    }
    // ảnh nhỏ RGBA cho đánh giá bóng
    const rs = new Uint8ClampedArray(sm.w * sm.h * 4);
    for (let y = 0; y < sm.h; y++) for (let x = 0; x < sm.w; x++) {
      const sx = M.min(w - 1, (x / sm.s) | 0), sy = M.min(h - 1, (y / sm.s) | 0), i = (sy * w + sx) * 4, o = (y * sm.w + x) * 4;
      rs[o] = rgba[i]; rs[o + 1] = rgba[i + 1]; rs[o + 2] = rgba[i + 2]; rs[o + 3] = 255;
    }
    const suggest = !reliable && corners && quadArea(corners) > 0.15 * w * h ? corners : null;
    return {
      corners: reliable ? corners : null, dewarp: model, kind, curvature,
      // Không đủ tin cậy để tự cắt nhưng có ứng viên → gợi ý khung ban đầu cho người dùng chỉnh
      suggest,
      // Chỉ tự làm thẳng theo dòng chữ khi KHÔNG có khung nào (tránh xoay chồng lên khung gợi ý)
      fineRotation: suggest ? 0 : fine,
      confidence: det.conf, issues: quality(w, h, sm.g, sm.w, sm.h, det, rs), width: w, height: h,
    };
  }

  /** Dựng ảnh đầu ra. scale = tỷ lệ ảnh nguồn hiện tại / ảnh gốc (xem trước < 1). */
  function render(rgba, w, h, p, scale = 1, f35 = null, bicubic = true) {
    let img = rgba, W = w, H = h;
    const corners = p.corners ? scaleQuad(p.corners, scale) : null;
    if (corners) {
      const model = makeModel(p.dewarp);
      let aspect, size;
      if (model) {
        aspect = snapAspect(model.aspect, p.paper || 'auto');
        size = outputSize(corners, aspect.ratio);
        img = warpModel(rgba, w, h, model, scale, size[0], size[1], bicubic);
      } else {
        aspect = estimateAspect(corners, w, h, f35 ? focalFrom35(f35, w, h) : null, p.paper || 'auto');
        size = outputSize(corners, aspect.ratio);
        img = warpQuad(rgba, w, h, corners, size[0], size[1], bicubic);
      }
      W = size[0]; H = size[1];
    }
    [img, W, H] = rotate90(img, W, H, p.rotation || 0);
    if (M.abs(p.fineRotation || 0) > 0.01) img = rotateFine(img, W, H, p.fineRotation);
    img = enhance(img, W, H, p);
    return { rgba: img, w: W, h: H };
  }

  function snapEdges(rgba, w, h, q) { return refineQuad(toGray(rgba, w, h), w, h, q).quad; }
  function dewarpWith(rgba, w, h, q, f35) {
    const gray = toGray(rgba, w, h), sm = downGray(gray, w, h, 720), det = detect(sm.g, sm.w, sm.h), sc = 1 / sm.s;
    const c = analyzeCurvature(gray, w, h, q, det.boundary.map(p => P(p.x * sc, p.y * sc)), f35 ? focalFrom35(f35, w, h) : defaultFocal(w, h));
    return { corners: c.model ? c.corners : q, dewarp: c.model, kind: c.kind };
  }

  /** Thu nhỏ RGBA theo trung bình khối (ảnh thu nhỏ, xem trước). */
  function downRGBA(rgba, w, h, maxSide) {
    const s = M.min(1, maxSide / M.max(w, h));
    if (s >= 1) return { rgba, w, h, s: 1 };
    const sw = M.max(1, M.round(w * s)), sh = M.max(1, M.round(h * s)), out = new Uint8ClampedArray(sw * sh * 4);
    for (let y = 0; y < sh; y++) {
      const y0 = M.floor(y / s), y1 = M.min(h, M.max(y0 + 1, M.floor((y + 1) / s)));
      for (let x = 0; x < sw; x++) {
        const x0 = M.floor(x / s), x1 = M.min(w, M.max(x0 + 1, M.floor((x + 1) / s)));
        let r = 0, g = 0, b = 0, n = 0;
        for (let yy = y0; yy < y1; yy++) for (let xx = x0; xx < x1; xx++) { const i = (yy * w + xx) * 4; r += rgba[i]; g += rgba[i + 1]; b += rgba[i + 2]; n++; }
        const o = (y * sw + x) * 4; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n; out[o + 3] = 255;
      }
    }
    return { rgba: out, w: sw, h: sh, s: sw / w };
  }

  const CV = {
    downRGBA,
    P, dist, quadOrder, quadArea, isConvex, homography, happly, toGray, downGray, detect, Tracker, lapVar,
    refineQuad, estimateAspect, snapAspect, outputSize, analyzeCurvature, makeModel, buildCylinder, classifyCurl,
    warpQuad, warpModel, rotate90, rotateFine, estimateSkew, enhance, bgModel, analyze, render, snapEdges, dewarpWith,
    polyfitRobust, polyval, NS,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = CV;
  else root.CV = CV;
})(typeof self !== 'undefined' ? self : this);
