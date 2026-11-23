"""Nắn mép quăn / gáy sách bằng mô hình 3D trụ (developable) – kiểm chứng.

Ý tưởng: mặt giấy = phần phẳng + phần uốn quanh trục song song với 1 cạnh.
1) Từ cạnh thẳng hoàn toàn (đối diện chỗ quăn) + 2 cạnh bên (phần phẳng) + tiêu cự
   → tư thế 3D của mặt phẳng giấy (điểm tụ trực giao).
2) Điểm ảnh của 2 cạnh bên ở vùng quăn được chiếu ngược lên mặt phẳng vuông góc
   chứa cạnh đó → mặt cắt (Y, Z) thật → độ dài cung.
3) Ánh xạ (X, S) trang phẳng → (X, Y(S), Z(S)) 3D → ảnh. Tỷ lệ trang suy ra luôn.
"""
import math, numpy as np, cv2, sys
sys.argv = sys.argv[:1]
import sim, curve

def h(p): return np.array([p[0], p[1], 1.0])

def fit_line_h(pts):
    c, d = sim.fit_line(np.asarray(pts, float))
    n = np.array([-d[1], d[0]])
    return np.array([n[0], n[1], -n @ c])  # dòng đồng nhất

def edge_points(gray, q, devs, R):
    """Điểm mép (ảnh) cho từng cạnh, dò quanh đường cong Coons dự đoán."""
    Hm = curve.homog(q)
    cen = curve.apply_h(Hm, np.array([[0.5, 0.5]]))[0]
    out = {}
    tg = np.linspace(0, 1, curve.NS)
    for name, pa, da, nom in curve.SIDES:
        K = 160
        ts = np.linspace(0.01, 0.99, K)
        p, n = curve.side_frame(Hm, name, ts, np.interp(ts, tg, devs[name]))
        if np.dot(cen - p[K // 2], n[K // 2]) < 0: n = -n
        found = {1: [], -1: []}; score = {1: 0, -1: 0}
        offs = np.arange(-R, R + 1, 1.0)
        for j in range(K):
            prof = np.array([sim.bilinear(gray, *(p[j] + n[j] * o)) for o in offs])
            gr = np.zeros_like(prof); gr[1:-1] = (prof[2:] - prof[:-2]) / 2
            for sg in (1, -1):
                gg = gr * sg; k = int(np.argmax(gg[2:-2])) + 2
                if gg[k] <= 4: continue
                a, b, c = gg[k-1], gg[k], gg[k+1]; den = a - 2*b + c
                sub = 0.5*(a-c)/den if abs(den) > 1e-9 else 0
                found[sg].append((ts[j], *(p[j] + n[j]*(offs[k] + np.clip(sub, -.5, .5)))))
                score[sg] += gg[k]
        sg = 1 if score[1] >= score[-1] else -1
        out[name] = np.array(found[sg])  # cột: t, x, y
    return out

ROT = {  # hướng quăn → nhãn cạnh chuẩn (top, right, bottom, left) và số lần xoay 90° cần bù
    "bottom": (("top", "right", "bottom", "left"), 0),
    "top":    (("bottom", "left", "top", "right"), 2),
    "left":   (("right", "bottom", "left", "top"), 3),
    "right":  (("left", "top", "right", "bottom"), 1),
}
# Tham số t của mỗi cạnh chạy theo chiều kim đồng hồ? (top: trái→phải; right: trên→dưới;
# bottom: trái→phải; left: trên→dưới) – cần đổi chiều khi xoay khung.

def curl_side(devs, thr=0.006):
    """Phát hiện mép bị quăn từ độ lệch của 2 cạnh vuông góc ở cùng 1 đầu."""
    sc = {
        "bottom": max(np.abs(devs["left"][-10:]).max(), np.abs(devs["right"][-10:]).max()),
        "top": max(np.abs(devs["left"][:10]).max(), np.abs(devs["right"][:10]).max()),
        "left": max(np.abs(devs["top"][:10]).max(), np.abs(devs["bottom"][:10]).max()),
        "right": max(np.abs(devs["top"][-10:]).max(), np.abs(devs["bottom"][-10:]).max()),
    }
    best = max(sc, key=sc.get)
    if sc[best] < thr: return None, sc
    others = [v for k, v in sc.items() if k != best]
    if max(others) > 0.6 * sc[best]: return "complex", sc
    return best, sc

def canon_points(pts_by_side, curl):
    names, _ = ROT[curl]
    top, right, bottom, left = names
    def orient(arr, rev):
        a = arr.copy()
        if rev: a[:, 0] = 1 - a[:, 0]
        return a
    # đảo tham số khi xoay để t chuẩn luôn: top/bottom trái→phải, left/right trên→dưới
    rev = {"bottom": (False, False, False, False), "top": (True, True, True, True),
           "left": (False, True, False, True), "right": (True, False, True, False)}[curl]
    return {"top": orient(pts_by_side[top], rev[0]), "right": orient(pts_by_side[right], rev[1]),
            "bottom": orient(pts_by_side[bottom], rev[2]), "left": orient(pts_by_side[left], rev[3])}

def build_curl_model(P, f, W, Himg, flat_until=0.55, end_corners=None):
    """P: điểm cạnh theo khung chuẩn (quăn ở dưới). Trả về hàm map(X,S)->ảnh và S_total."""
    K = np.array([[f, 0, W/2], [0, f, Himg/2], [0, 0, 1]]); Ki = np.linalg.inv(K)
    lt = fit_line_h(P["top"][:, 1:])
    ll = fit_line_h(P["left"][P["left"][:, 0] < flat_until, 1:])
    lr = fit_line_h(P["right"][P["right"][:, 0] < flat_until, 1:])
    TL = np.cross(lt, ll); TR = np.cross(lt, lr); vy = np.cross(ll, lr)
    TL = TL / TL[2]; TR = TR / TR[2]
    om = Ki.T @ Ki
    a = TR @ om @ vy; b = -(TL @ om @ vy)
    vx = a * TL + b * TR
    dx = Ki @ vx; dy = Ki @ vy
    dx /= np.linalg.norm(dx); dy /= np.linalg.norm(dy)
    rtl = Ki @ TL; rtr = Ki @ TR
    # hướng dx: từ TL sang TR
    if dx @ (rtr / rtr[2] - rtl / rtl[2]) < 0: dx = -dx
    # s*rtl + 1*dx = t*rtr
    A = np.stack([rtl, -rtr], 1)
    st, *_ = np.linalg.lstsq(A, -dx, rcond=None)
    Ptl = st[0] * rtl
    # hướng dy: về phía dưới trang (cùng phía các điểm cạnh trái)
    pl = P["left"][len(P["left"]) // 2, 1:]
    rl = Ki @ h(pl); lam = (Ptl @ dx) / (rl @ dx) if abs(rl @ dx) > 1e-12 else 1
    if (lam * rl - Ptl) @ dy < 0: dy = -dy
    dy = dy - (dy @ dx) * dx; dy /= np.linalg.norm(dy)
    n = np.cross(dx, dy)
    prof = []
    for side, X0 in (("left", 0.0), ("right", 1.0)):
        for t, x, y in P[side]:
            r = Ki @ np.array([x, y, 1.0])
            den = r @ dx
            if abs(den) < 1e-12: continue
            lam = (Ptl @ dx + X0) / den
            Q = lam * r - Ptl
            prof.append((Q @ dy, Q @ n))
    Yend = None
    if end_corners is not None:
        ends = []
        for (x, y), X0 in zip(end_corners, (0.0, 1.0)):
            r = Ki @ np.array([x, y, 1.0]); lam = (Ptl @ dx + X0) / (r @ dx)
            Q = lam * r - Ptl; ends.append((Q @ dy, Q @ n)); prof.append((Q @ dy, Q @ n))
        Yend = max(e[0] for e in ends)
    prof = np.array(sorted(prof))
    Ys, Zs = prof[:, 0], prof[:, 1]
    Ymax = Yend if Yend is not None else Ys.max()
    # Mô hình: phẳng (Z=0) tới Y0, sau đó Z = c2 (Y-Y0)^2 + c3 (Y-Y0)^3. Chọn Y0 tốt nhất.
    flatZ = np.median(Zs[Ys < Ymax * 0.4]) if np.any(Ys < Ymax * 0.4) else 0
    Zs = Zs - flatZ
    best = (1e18, 0, 0, Ymax)
    for Y0 in np.linspace(0.3 * Ymax, 0.97 * Ymax, 68):
        m = Ys > Y0
        if m.sum() < 8: continue
        d = Ys[m] - Y0
        A = np.stack([d**2, d**3], 1)
        c, *_ = np.linalg.lstsq(A, Zs[m], rcond=None)
        r = A @ c - Zs[m]
        # điểm ngoại lai (sai số dò mép) bị chặn để không kéo lệch mô hình
        sse = np.sum(np.minimum(r**2, (0.004)**2)) + np.sum(np.minimum(Zs[~m]**2, (0.004)**2))
        if sse < best[0]: best = (sse, c[0], c[1], Y0)
    _, c2, c3, Y0 = best
    grid = np.linspace(0, Ymax, 400)
    dd = np.clip(grid - Y0, 0, None)
    Zg = c2 * dd**2 + c3 * dd**3
    seg = np.sqrt(np.diff(grid)**2 + np.diff(Zg)**2)
    S = np.concatenate([[0], np.cumsum(seg)])
    def mapf(X, Sq):
        Y = np.interp(Sq, S, grid); Z = np.interp(Sq, S, Zg)
        Pw = Ptl[None, :] + X[:, None] * dx + Y[:, None] * dy + Z[:, None] * n
        p = Pw @ K.T
        return p[:, 0] / p[:, 2], p[:, 1] / p[:, 2]
    return mapf, S[-1], Zg.max() - Zg.min()

def run(mode, f_hint=1550.0, **cam):
    doc = sim.make_doc()
    img = curve.render_curved(doc, mode, **cam)
    Hh, W = img.shape[:2]
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY); gf = gray.astype(np.float32)
    s = 720 / max(W, Hh)
    small = cv2.resize(gray, (round(W*s), round(Hh*s)), interpolation=cv2.INTER_AREA)
    q0, bnd = curve.detect_with_boundary(small); q0 /= s; bnd /= s
    q1, _ = sim.refine_quad(gf, q0)
    R = max(6.0, 0.012 * math.hypot(W, Hh))
    q = q1.copy(); init = curve.curves_from_boundary(bnd, q)
    for _ in range(3):
        coefs = curve.refine_curves(gf, q, init, R)
        q = curve.update_corners(q, coefs)
        tt = np.linspace(.03, .97, 60)
        init = {k: (tt, np.polyval(c, tt) - (np.polyval(c, 0) + (np.polyval(c, 1) - np.polyval(c, 0)) * tt)) for k, c in coefs.items()}
    devs = curve.sample_devs(curve.refine_curves(gf, q, init, R))
    side, sc = curl_side(devs)
    truth = cv2.cvtColor(doc, cv2.COLOR_BGR2GRAY)
    if side in (None, "complex"):
        print(f"{mode:12s} quăn: {side}  {({k: round(v*100,2) for k,v in sc.items()})}")
        return
    pts = edge_points(gf, q, devs, R)
    P = canon_points(pts, side)
    names = ROT[side][0]
    idx = {frozenset(("top","left")):0, frozenset(("top","right")):1, frozenset(("right","bottom")):2, frozenset(("bottom","left")):3}
    bl = q[idx[frozenset((names[2], names[3]))]]; br = q[idx[frozenset((names[1], names[2]))]]
    mapf, Stot, zr = build_curl_model(P, f_hint, W, Hh, end_corners=(bl, br))
    ow = 1050; ohc = round(ow * Stot)   # khung chuẩn: rộng 1, dài Stot
    k = ROT[side][1]
    cw, ch = (ow, ohc)
    Xg, Sg = np.meshgrid((np.arange(cw) + .5) / cw, (np.arange(ch) + .5) / ch * Stot)
    mx, my = mapf(Xg.ravel(), Sg.ravel())
    out = cv2.remap(gray, mx.reshape(ch, cw).astype(np.float32), my.reshape(ch, cw).astype(np.float32), cv2.INTER_LINEAR)
    out = np.rot90(out, k)  # quay về hướng gốc (np.rot90 ngược chiều kim đồng hồ)
    out = np.ascontiguousarray(out)
    e = curve.misalign(out, truth)
    ratio = out.shape[1] / out.shape[0]
    print(f"{mode:12s} quăn: {side:6s} nâng {zr*210:.0f}mm | lệch dòng chữ {e:3d} px/1000 | tỷ lệ {ratio:.4f} (A4 0.7071)")
    return img, out

if __name__ == "__main__":
    for m in ["curl_bottom", "book", "flat", "wave"]:
        run(m)
