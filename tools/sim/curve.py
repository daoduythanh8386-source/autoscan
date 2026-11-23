"""Mô phỏng & kiểm chứng NẮN GIẤY CONG / CONG MÉP (port sát sang Dart sau).

Chuỗi: nhận diện (sim.detect + mặt nạ) → góc tinh chỉnh (sim.refine_quad) →
đường cong 4 mép (từ biên mặt nạ, tinh chỉnh độ phân giải đầy đủ) →
lưới Coons trên nền homography → (tuỳ chọn) bù dịch dọc theo dòng chữ.
"""
import math
import sys

import cv2
import numpy as np

sys.argv = sys.argv[:1]
import sim

rng = np.random.default_rng(7)
NS = 33  # số mẫu mỗi đường cong (lưu trong EditParams)


# ----------------------------------------------------------- dựng ảnh cong
def bend_profile(n, length, start_frac, max_angle_deg, at_end):
    """Trả về (x_proj, z) theo độ dài cung s∈[0,length]: phẳng rồi uốn dần ở 1 đầu."""
    s = np.linspace(0, length, n)
    u = s / length
    if at_end:
        t = np.clip((u - start_frac) / (1 - start_frac), 0, 1)
    else:
        t = np.clip((start_frac - u) / start_frac, 0, 1)
    theta = np.radians(max_angle_deg) * t ** 2
    ds = length / (n - 1)
    if at_end:
        x = np.concatenate([[0], np.cumsum(np.cos(theta[1:]) * ds)])
        z = np.concatenate([[0], np.cumsum(np.sin(theta[1:]) * ds)])
    else:
        # uốn ở đầu: tích phân từ cuối về đầu
        x = length - np.concatenate([np.cumsum((np.cos(theta[::-1][1:]) * ds))[::-1], [0]])
        z = np.concatenate([np.cumsum((np.sin(theta[::-1][1:]) * ds))[::-1], [0]])
    return x, z


def render_curved(doc, mode, tilt_x=15, tilt_y=5, roll=3, dist=0.45, img_w=1500, img_h=2000,
                  f=1550.0):
    dh, dw = doc.shape[:2]
    W, H = 0.210, 0.297
    ys, xs = np.mgrid[0:dh, 0:dw]
    X = xs / (dw - 1) * W
    Y = ys / (dh - 1) * H
    Z = np.zeros_like(X)
    if mode == "book":  # gáy sách bên trái cong lên
        px, pz = bend_profile(dw, W, 0.45, 38, at_end=False)
        X = np.broadcast_to(px[None, :], X.shape).copy()
        Z = np.broadcast_to(pz[None, :], X.shape).copy()
    elif mode == "curl_bottom":  # mép dưới quăn lên
        py, pz = bend_profile(dh, H, 0.78, 50, at_end=True)
        Y = np.broadcast_to(py[:, None], X.shape).copy()
        Z = np.broadcast_to(pz[:, None], X.shape).copy()
    elif mode == "wave":  # giấy gợn sóng nhẹ (gấp đôi)
        Z = 0.012 * np.sin(np.pi * X / W) ** 2 * (1 + 0.3 * np.sin(2 * np.pi * Y / H))
    X = X - X.max() / 2
    Y = Y - Y.max() / 2
    pts = np.stack([X, Y, -Z], -1).reshape(-1, 3)
    rx, ry, rz = map(math.radians, (tilt_x, tilt_y, roll))
    Rx = np.array([[1, 0, 0], [0, math.cos(rx), -math.sin(rx)], [0, math.sin(rx), math.cos(rx)]])
    Ry = np.array([[math.cos(ry), 0, math.sin(ry)], [0, 1, 0], [-math.sin(ry), 0, math.cos(ry)]])
    Rz = np.array([[math.cos(rz), -math.sin(rz), 0], [math.sin(rz), math.cos(rz), 0], [0, 0, 1]])
    P = pts @ (Rz @ Ry @ Rx).T + np.array([0, 0, dist])
    u = f * P[:, 0] / P[:, 2] + img_w / 2
    v = f * P[:, 1] / P[:, 2] + img_h / 2
    # splat
    yy, xx = np.mgrid[0:img_h, 0:img_w]
    base = 70 + 18 * np.sin(xx / 25.0) + 10 * np.sin(yy / 8.0 + xx / 60.0)
    img = np.dstack([base * 0.7, base * 0.85, base]).astype(np.float64)
    acc = np.zeros((img_h, img_w, 3)); cnt = np.zeros((img_h, img_w))
    ui = np.round(u).astype(int); vi = np.round(v).astype(int)
    ok = (ui >= 0) & (ui < img_w) & (vi >= 0) & (vi < img_h)
    col = doc.reshape(-1, 3).astype(np.float64)
    # tô bóng theo độ nghiêng bề mặt (giấy cong tối hơn)
    shade = np.ones(len(col))
    if mode != "flat":
        zz = Z.reshape(-1)
        shade = 1 - 2.5 * np.abs(np.gradient(Z, axis=1).reshape(-1) * dw / W + np.gradient(Z, axis=0).reshape(-1) * dh / H) * 0.15
        shade = np.clip(shade, 0.6, 1)
    np.add.at(acc, (vi[ok], ui[ok]), col[ok] * shade[ok, None])
    np.add.at(cnt, (vi[ok], ui[ok]), 1)
    m = cnt > 0
    img[m] = acc[m] / cnt[m, None]
    img = cv2.GaussianBlur(img.astype(np.float32), (0, 0), 0.8)
    img += rng.normal(0, 2.5, img.shape)
    return np.clip(img, 0, 255).astype(np.uint8)


# ------------------------------------------------------- nhận diện + mặt nạ
def detect_with_boundary(gray_small):
    h, w = gray_small.shape
    g = sim.box_blur(sim.box_blur(gray_small, 2), 2)
    t = sim.otsu(g)
    mask = (g > t).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=4)
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    comp = (lab == k).astype(np.uint8)
    cs, _ = cv2.findContours(comp, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    c = max(cs, key=len).reshape(-1, 2).astype(float) + 0.5
    hull = cv2.convexHull(c.astype(np.float32)).reshape(-1, 2).astype(float)
    q = sim.max_area_quad(hull)
    return q, c


# ------------------------------------------------------------ đường cong
def homog(q):
    """H: đơn vị → ảnh."""
    return cv2.getPerspectiveTransform(np.float32([[0, 0], [1, 0], [1, 1], [0, 1]]), np.float32(q))


def apply_h(Hm, pts):
    p = np.c_[pts, np.ones(len(pts))] @ Hm.T
    return p[:, :2] / p[:, 2:3]


def polyfit_robust(t, d, deg=4):
    keep = np.ones(len(t), bool)
    c = np.polyfit(t, d, deg)
    for _ in range(3):
        r = np.abs(np.polyval(c, t) - d)
        thr = max(np.median(r[keep]) * 3, 1e-3)
        keep = r <= thr
        if keep.sum() < deg + 3:
            break
        c = np.polyfit(t[keep], d[keep], deg)
    return c


SIDES = [  # (tên, trục tham số, trục lệch, giá trị danh định)
    ("top", 0, 1, 0.0), ("right", 1, 0, 1.0), ("bottom", 0, 1, 1.0), ("left", 1, 0, 0.0)]


def curves_from_boundary(boundary_img, q):
    """Đường cong lệch (đơn vị) của 4 mép từ biên mặt nạ: dict side -> (t, dev)."""
    Hm = homog(q)
    uv = apply_h(np.linalg.inv(Hm), boundary_img)
    out = {}
    for name, pa, da, nom in SIDES:
        t, dv = uv[:, pa], uv[:, da] - nom
        sel = (t > 0.03) & (t < 0.97) & (np.abs(dv) < 0.15)
        # mỗi điểm thuộc mép gần nhất
        out[name] = (t[sel], dv[sel])
    return out


def side_frame(Hm, name, t, dev):
    """Điểm ảnh & pháp tuyến ảnh tại tham số t (lệch dev, đơn vị)."""
    pa = [s for s in SIDES if s[0] == name][0]
    _, ia, idv, nom = pa
    uv = np.zeros((len(t), 2)); uv[:, ia] = t; uv[:, idv] = nom + dev
    uv2 = uv.copy(); uv2[:, idv] += 1e-3
    p = apply_h(Hm, uv); p2 = apply_h(Hm, uv2)
    n = p2 - p; n /= np.linalg.norm(n, axis=1, keepdims=True)
    return p, n


def refine_curves(gray, q, init, R):
    """Tinh chỉnh độ phân giải đầy đủ: dò gradient quanh đường cong dự đoán."""
    Hm = homog(q); Hinv = np.linalg.inv(Hm)
    cen = apply_h(Hm, np.array([[0.5, 0.5]]))[0]
    coefs = {}
    for name, pa, da, nom in SIDES:
        t0, d0 = init[name]
        c0 = polyfit_robust(t0, d0, 4) if len(t0) > 10 else np.zeros(5)
        K = 120
        ts = np.linspace(0.02, 0.98, K)
        p, n = side_frame(Hm, name, ts, np.polyval(c0, ts))
        # n hướng vào trong
        if np.dot(cen - p[K // 2], n[K // 2]) < 0:
            n = -n
        found = {1: [], -1: []}; score = {1: 0, -1: 0}
        offs = np.arange(-R, R + 1, 1.0)
        for j in range(K):
            prof = np.array([sim.bilinear(gray, *(p[j] + n[j] * o)) for o in offs])
            gr = np.zeros_like(prof); gr[1:-1] = (prof[2:] - prof[:-2]) / 2
            for sg in (1, -1):
                gg = gr * sg; k = int(np.argmax(gg[2:-2])) + 2
                if gg[k] <= 4: continue
                a, b, c = gg[k - 1], gg[k], gg[k + 1]; den = a - 2 * b + c
                sub = 0.5 * (a - c) / den if abs(den) > 1e-9 else 0
                found[sg].append(p[j] + n[j] * (offs[k] + np.clip(sub, -.5, .5)))
                score[sg] += gg[k]
        sg = 1 if score[1] >= score[-1] else -1
        pts = np.array(found[sg])
        if len(pts) < K * 0.4:
            coefs[name] = c0; continue
        uv = apply_h(Hinv, pts)
        coefs[name] = polyfit_robust(uv[:, pa], uv[:, da] - nom, 4)
    return coefs


def update_corners(q, coefs):
    """Dịch góc theo độ lệch của 2 mép kề tại đầu mút, rồi lặp lại."""
    Hm = homog(q)
    ends = {
        0: (0.0 + np.polyval(coefs["left"], 0.0), 0.0 + np.polyval(coefs["top"], 0.0)),
        1: (1.0 + np.polyval(coefs["right"], 0.0), 0.0 + np.polyval(coefs["top"], 1.0)),
        2: (1.0 + np.polyval(coefs["right"], 1.0), 1.0 + np.polyval(coefs["bottom"], 1.0)),
        3: (0.0 + np.polyval(coefs["left"], 1.0), 1.0 + np.polyval(coefs["bottom"], 0.0)),
    }
    return apply_h(Hm, np.array([ends[i] for i in range(4)]))


def sample_devs(coefs):
    """Mẫu lệch đã trừ phần tuyến tính để = 0 ở 2 đầu (NS mẫu mỗi mép)."""
    t = np.linspace(0, 1, NS)
    out = {}
    for k, c in coefs.items():
        d = np.polyval(c, t)
        d = d - (d[0] + (d[-1] - d[0]) * t)
        out[k] = d
    return out


def coons_map(q, devs, ow, oh, dy=None, vmap=None):
    """Bảng ánh xạ (map_x, map_y) đầu ra → ảnh nguồn."""
    Hm = homog(q)
    u = (np.arange(ow) + 0.5) / ow
    v = (np.arange(oh) + 0.5) / oh
    U, V = np.meshgrid(u, v)
    if vmap is not None:
        V = np.interp(V, np.linspace(0, 1, len(vmap)), vmap)
    tgrid = np.linspace(0, 1, NS)
    vt = np.interp(U, tgrid, devs["top"]); vb = np.interp(U, tgrid, devs["bottom"])
    ul = np.interp(V, tgrid, devs["left"]); ur = np.interp(V, tgrid, devs["right"])
    X = U + (1 - U) * ul + U * ur
    Y = V + (1 - V) * vt + V * vb
    if dy is not None:
        Y = Y + dy(U, V)
    P = np.stack([X.ravel(), Y.ravel()], 1)
    S = apply_h(Hm, P)
    return S[:, 0].reshape(oh, ow).astype(np.float32), S[:, 1].reshape(oh, ow).astype(np.float32)


# --------------------------------------------------- bù theo dòng chữ
def textline_dy(gray_rect, strips=16, bands=4):
    """Ước lượng dịch dọc dư (đơn vị chiều cao) theo dòng chữ: trả hàm dy(U,V) hoặc None."""
    h, w = gray_rect.shape
    g = gray_rect.astype(np.float32)
    bg = cv2.blur(g, (31, 31))
    ink = (g < bg * 0.75).astype(np.float32)
    sw = w // strips
    maxs = int(0.03 * h)
    table = np.zeros((bands, strips))
    ok_any = False
    bh = h // bands
    for b in range(bands):
        y0 = max(0, b * bh - bh // 4); y1 = min(h, (b + 1) * bh + bh // 4)
        profs = [ink[y0:y1, s * sw:(s + 1) * sw].sum(1) for s in range(strips)]
        mid = strips // 2
        offs = np.zeros(strips)
        good = True
        for direction in (1, -1):
            s = mid
            while 0 <= s + direction < strips:
                a, c = profs[s], profs[s + direction]
                if a.sum() < 20 or c.sum() < 20:
                    offs[s + direction] = offs[s]; s += direction; continue
                a = a - a.mean(); c = c - c.mean()
                best, bk = -1e18, 0
                for k in range(-maxs // 4, maxs // 4 + 1):  # bước nhỏ giữa 2 dải kề
                    if k >= 0: v = np.dot(a[k:], c[:len(c) - k])
                    else: v = np.dot(a[:k], c[-k:])
                    if v > best: best, bk = v, k
                # c dịch bk so với a  → offset cộng dồn
                offs[s + direction] = offs[s] - bk
                s += direction
        table[b] = offs - offs.mean()
        ok_any = True
    # làm mượt: bậc 3 theo x mỗi band
    xs = (np.arange(strips) + 0.5) / strips
    fit = np.array([np.polyval(np.polyfit(xs, table[b], 3), xs) for b in range(bands)])
    if np.abs(fit).max() < 1.5:
        return None, fit
    yb = (np.arange(bands) + 0.5) / bands

    def dy(U, V):
        # nội suy song tuyến trên lưới (band, strip); đổi px → đơn vị
        fx = np.clip(U * strips - 0.5, 0, strips - 1); fy = np.clip(V * bands - 0.5, 0, bands - 1)
        x0 = np.floor(fx).astype(int); y0 = np.floor(fy).astype(int)
        x1 = np.minimum(x0 + 1, strips - 1); y1 = np.minimum(y0 + 1, bands - 1)
        ax = fx - x0; ay = fy - y0
        top = fit[y0, x0] * (1 - ax) + fit[y0, x1] * ax
        bot = fit[y1, x0] * (1 - ax) + fit[y1, x1] * ax
        return (top * (1 - ay) + bot * ay) / h
    return dy, fit


# ------------------------------------------------------------- đo kết quả
def misalign_h(out_gray, truth_gray):
    """Lệch NGANG lớn nhất (px theo chiều rộng 700) đo bằng cột kẻ bảng."""
    a = cv2.resize(out_gray, (700, 1000), interpolation=cv2.INTER_AREA).astype(np.float32)
    b = cv2.resize(truth_gray, (700, 1000), interpolation=cv2.INTER_AREA).astype(np.float32)
    # dải bảng: y 1200..1700 trên 2970 → 404..572
    worst = 0
    for x0 in range(0, 700 - 140, 70):
        pa = 255 - a[410:570, x0:x0 + 140].min(0); pb = 255 - b[410:570, x0:x0 + 140].min(0)
        pa = pa - pa.mean(); pb = pb - pb.mean()
        if np.abs(pb).max() < 20: continue
        best, bk = -1e18, 0
        for k in range(-30, 31):
            v = np.dot(pa[max(0, k):len(pa) + min(0, k)], pb[max(0, -k):len(pb) + min(0, -k)])
            if v > best: best, bk = v, k
        worst = max(worst, abs(bk))
    return worst


def misalign(out_gray, truth_gray, strips=12):
    """Lệch dọc lớn nhất (px theo chiều cao 1000) giữa từng dải của kết quả và đáp án."""
    h = 1000
    a = cv2.resize(out_gray, (700, h), interpolation=cv2.INTER_AREA).astype(np.float32)
    b = cv2.resize(truth_gray, (700, h), interpolation=cv2.INTER_AREA).astype(np.float32)
    sw = 700 // strips
    worst = 0
    for s in range(strips):
        for (y0, y1) in [(80, 380), (350, 650), (620, 920)]:
            pa = 255 - a[y0:y1, s * sw:(s + 1) * sw].mean(1); pb = 255 - b[y0:y1, s * sw:(s + 1) * sw].mean(1)
            pa -= pa.mean(); pb -= pb.mean()
            best, bk = -1e18, 0
            for k in range(-30, 31):
                v = np.dot(pa[max(0, k):len(pa) + min(0, k)], pb[max(0, -k):len(pb) + min(0, -k)])
                if v > best: best, bk = v, k
            worst = max(worst, abs(bk))
    return worst


def run(mode, **cam):
    doc = sim.make_doc()
    img = render_curved(doc, mode, **cam)
    H, W = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    s = 720 / max(W, H)
    small = cv2.resize(gray, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    q0, bnd = detect_with_boundary(small)
    q0 = q0 / s; bnd = bnd / s
    gf = gray.astype(np.float32)
    q1, _ = sim.refine_quad(gf, q0)
    R = max(6.0, 0.012 * math.hypot(W, H))
    # cũ: homography phẳng
    r, _ = sim.true_aspect(q1, W, H, 1550.0); r, _ = sim.snap(r)
    ow = 1050; oh = round(ow / r)
    zero = {k: np.zeros(NS) for k in ("top", "right", "bottom", "left")}
    mx, my = coons_map(q1, zero, ow, oh)
    flat = cv2.remap(gray, mx, my, cv2.INTER_LINEAR)
    # mới: đường cong
    q = q1.copy()
    init = curves_from_boundary(bnd, q)
    for _ in range(3):
        coefs = refine_curves(gf, q, init, R)
        q = update_corners(q, coefs)
        init = {k: (np.linspace(.03, .97, 60), np.polyval(c, np.linspace(.03, .97, 60)) -
                    (np.polyval(c, 0) + (np.polyval(c, 1) - np.polyval(c, 0)) * np.linspace(.03, .97, 60)))
                for k, c in coefs.items()}
    devs = sample_devs(refine_curves(gf, q, init, R))
    curv = max(np.abs(d).max() for d in devs.values())
    mx, my = coons_map(q, devs, ow, oh)
    curved = cv2.remap(gray, mx, my, cv2.INTER_LINEAR)
    vm, _ = vertical_reparam(curved, devs)
    oh2 = oh
    if vm is not None:
        vmap, total = vm
        mx, my = coons_map(q, devs, ow, oh2, vmap=vmap)
        curved = cv2.remap(gray, mx, my, cv2.INTER_LINEAR)
    else:
        vmap = None
    dyf, fit = (None, np.zeros(1))
    if curv > 0.006:
        dyf, fit = textline_dy(curved)
    if dyf is not None:
        mx, my = coons_map(q, devs, ow, oh2, dyf, vmap=vmap)
        final = cv2.remap(gray, mx, my, cv2.INTER_LINEAR)
    else:
        final = curved
    truth = cv2.cvtColor(doc, cv2.COLOR_BGR2GRAY)
    e_flat, e_curve, e_final = misalign(flat, truth), misalign(curved, truth), misalign(final, truth)
    print('   vmap:', vm is not None)
    print(f"{mode:12s} độ cong mép {curv*100:4.1f}%  | lệch dòng chữ (px/1000): phẳng {e_flat:3d} → "
          f"mép cong {e_curve:3d} → +dòng chữ {e_final:3d}   (dy max {np.abs(fit).max():.1f}px)")
    return img, flat, final, truth


# ------------------------------------------- bù co giãn dọc ở mép quăn
def line_pitch(profile, lo, hi):
    p = profile - profile.mean()
    if np.abs(p).sum() < 1e-6: return None, 0
    ac = np.array([np.dot(p[:-k], p[k:]) for k in range(1, hi + 2)]) / np.dot(p, p)
    k = int(np.argmax(ac[lo - 1:hi])) + lo
    if k <= lo or k >= hi: return None, 0
    a, b, c = ac[k - 2], ac[k - 1], ac[k]
    den = a - 2 * b + c
    sub = 0.5 * (a - c) / den if abs(den) > 1e-9 else 0
    return k + sub, ac[k - 1]


def vertical_reparam(gray_rect, devs, thr=0.006):
    """Ánh xạ v_out → v_src làm đều khoảng cách dòng ở vùng mép trên/dưới bị quăn.
    Trả về mảng (NS2,) v_src theo v_out đều, hoặc None nếu không áp dụng."""
    h, w = gray_rect.shape
    top_curl = np.abs(devs["top"]).max() > thr or np.abs(devs["left"][:8]).max() > thr or np.abs(devs["right"][:8]).max() > thr
    bot_curl = np.abs(devs["bottom"]).max() > thr or np.abs(devs["left"][-8:]).max() > thr or np.abs(devs["right"][-8:]).max() > thr
    if not (top_curl or bot_curl): return None, None
    g = gray_rect.astype(np.float32)
    ink = (g < cv2.blur(g, (31, 31)) * 0.75).astype(np.float32)
    x0, x1 = int(w * 0.15), int(w * 0.85)
    prof = ink[:, x0:x1].sum(1)
    pref, cref = line_pitch(prof[int(h*.3):int(h*.7)], max(4, h // 200), h // 15)
    if pref is None or cref < 0.3: return None, None
    win = int(pref * 4)
    ys = np.arange(win // 2, h - win // 2, max(2, int(pref / 2)))
    ratio = np.ones(len(ys))
    for i, y in enumerate(ys):
        zone = y / h
        if not ((top_curl and zone < 0.35) or (bot_curl and zone > 0.65)): continue
        pl, cl = line_pitch(prof[y - win // 2:y + win // 2], max(3, int(pref * 0.45)), int(pref * 1.5))
        if pl is not None and cl > 0.35:
            ratio[i] = np.clip(pl / pref, 0.45, 1.3)
    # làm mượt
    ratio = np.convolve(np.pad(ratio, 2, mode='edge'), np.ones(5) / 5, mode='valid')
    if np.abs(ratio - 1).max() < 0.04: return None, ratio
    # g'(y_out) = ratio(v)  → tích phân theo v: y_out(v) = ∫ 1/ratio dv
    vv = np.linspace(0, 1, 257)
    rv = np.interp(vv * h, ys, ratio)
    yout = np.concatenate([[0], np.cumsum((1 / rv[1:] + 1 / rv[:-1]) / 2 * np.diff(vv))])
    total = yout[-1]
    yout /= total
    # đảo ngược: v_src theo y_out đều
    vsrc = np.interp(np.linspace(0, 1, 257), yout, vv)
    return (vsrc, total), ratio


if __name__ == "__main__":
    outs = {}
    for mode in ["flat", "curl_bottom", "book", "wave"]:
        outs[mode] = run(mode)
    np.save("/tmp/curve_outs.npy", np.array([0]))
    for mode in ["curl_bottom", "book"]:
        img, flat, final, truth = outs[mode]
        th = 800
        def fit(a):
            if a.ndim == 2: a = cv2.cvtColor(a, cv2.COLOR_GRAY2BGR)
            return cv2.resize(a, (round(a.shape[1] * th / a.shape[0]), th), interpolation=cv2.INTER_AREA)
        pad = np.full((th, 24, 3), 255, np.uint8)
        panel = np.hstack([fit(img), pad, fit(flat), pad, fit(final)])
        bar = np.full((60, panel.shape[1], 3), 255, np.uint8)
        x1 = fit(img).shape[1] + 30; x2 = x1 + fit(flat).shape[1] + 24
        for x, t in [(8, "Anh chup"), (x1, "Chi nan phang (cu)"), (x2, "Nan cong (moi)")]:
            cv2.putText(bar, t, (x, 42), cv2.FONT_HERSHEY_SIMPLEX, 1.1, (0, 0, 0), 2)
        cv2.imwrite(f"curve_{mode}.jpg", np.vstack([bar, panel]), [cv2.IMWRITE_JPEG_QUALITY, 85])


