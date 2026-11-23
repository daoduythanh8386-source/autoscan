"""Mô phỏng chuỗi scan để kiểm chứng thuật toán trước khi viết Dart.

Tạo ảnh "chụp bằng điện thoại" từ một tờ A4 tổng hợp với mô hình camera thật
(tiêu cự, góc nghiêng 3D), rồi chạy: nhận diện (port từ Dart) → tinh chỉnh cạnh
→ ước lượng tỷ lệ → nắn phẳng, và đo sai số so với đáp án.
"""
import math
import sys

import cv2
import numpy as np

rng = np.random.default_rng(1)


# ------------------------------------------------------------------ dữ liệu
def make_doc(w=2100, h=2970):
    d = np.full((h, w, 3), (232, 238, 242), np.uint8)  # BGR giấy hơi vàng
    y = 180
    while y < h - 200:
        y += int(rng.integers(34, 72))  # khoảng cách dòng không đều: tránh nhập nhằng chu kỳ khi đo
        x = 160
        while x < w - 200:
            ln = int(rng.integers(30, 160))
            cv2.rectangle(d, (x, y), (min(x + ln, w - 160), y + 18), (30, 30, 30), -1)
            x += ln + int(rng.integers(14, 30))
    cv2.circle(d, (1500, 2500), 160, (40, 40, 200), 10)
    for i in range(0, 900, 2):  # khung bảng
        pass
    cv2.rectangle(d, (160, 1200), (1940, 1700), (20, 20, 20), 3)
    for x in range(160, 1940, 356):
        cv2.line(d, (x, 1200), (x, 1700), (20, 20, 20), 3)
    return d


def camera_shot(doc, tilt_x, tilt_y, roll, dist, img_w=3000, img_h=4000, f=3100.0,
                shift=(0, 0), bg="desk"):
    dh, dw = doc.shape[:2]
    # Tờ giấy trong hệ mét: A4 0.210 x 0.297, tâm tại gốc.
    W, H = 0.210, 0.297
    obj = np.array([[-W / 2, -H / 2, 0], [W / 2, -H / 2, 0], [W / 2, H / 2, 0], [-W / 2, H / 2, 0]])
    rx, ry, rz = map(math.radians, (tilt_x, tilt_y, roll))
    Rx = np.array([[1, 0, 0], [0, math.cos(rx), -math.sin(rx)], [0, math.sin(rx), math.cos(rx)]])
    Ry = np.array([[math.cos(ry), 0, math.sin(ry)], [0, 1, 0], [-math.sin(ry), 0, math.cos(ry)]])
    Rz = np.array([[math.cos(rz), -math.sin(rz), 0], [math.sin(rz), math.cos(rz), 0], [0, 0, 1]])
    R = Rz @ Ry @ Rx
    pts = (R @ obj.T).T + np.array([shift[0], shift[1], dist])
    K = np.array([[f, 0, img_w / 2], [0, f, img_h / 2], [0, 0, 1]])
    proj = (K @ pts.T).T
    proj = proj[:, :2] / proj[:, 2:3]
    src = np.float32([[0, 0], [dw, 0], [dw, dh], [0, dh]])
    Hm = cv2.getPerspectiveTransform(src, np.float32(proj))
    # Nền bàn gỗ tối có vân
    yy, xx = np.mgrid[0:img_h, 0:img_w]
    base = 70 + 18 * np.sin(xx / 37.0) + 10 * np.sin(yy / 11.0 + xx / 90.0)
    bgimg = np.dstack([base * 0.7, base * 0.85, base]).astype(np.float32)
    warped = cv2.warpPerspective(doc, Hm, (img_w, img_h), flags=cv2.INTER_LINEAR,
                                 borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
    mask = cv2.warpPerspective(np.full((dh, dw), 255, np.uint8), Hm, (img_w, img_h))
    m = (mask.astype(np.float32) / 255)[..., None]
    img = warped.astype(np.float32) * m + bgimg * (1 - m)
    # bóng/ánh sáng không đều + nhoè quang học + nhiễu
    shade = 0.65 + 0.35 * (xx / img_w)[..., None]
    img = img * shade
    img = cv2.GaussianBlur(img, (0, 0), 1.2)
    img += rng.normal(0, 3, img.shape)
    return np.clip(img, 0, 255).astype(np.uint8), proj


# --------------------------------------------------- port nhận diện (Dart)
def box_blur(g, r):
    k = 2 * r + 1
    return cv2.blur(g, (k, k), borderType=cv2.BORDER_REPLICATE)


def otsu(g):
    t, _ = cv2.threshold(g, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    return int(t)


def quad_order(p):
    p = np.asarray(p, float)
    c = p.mean(0)
    ang = np.arctan2(p[:, 1] - c[1], p[:, 0] - c[0])
    s = p[np.argsort(ang)]
    start = int(np.argmin(s[:, 0] + s[:, 1]))
    return np.roll(s, -start, axis=0)


def area(q):
    x, y = q[:, 0], q[:, 1]
    return abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1))) / 2


def max_area_quad(hull):
    def arg(f):
        return int(np.argmax([f(p) for p in hull]))
    idx = [arg(lambda p: -(p[0] + p[1])), arg(lambda p: p[0] - p[1]),
           arg(lambda p: p[0] + p[1]), arg(lambda p: p[1] - p[0])]
    best = area(hull[idx])
    for _ in range(4):
        imp = False
        for k in range(4):
            for c in range(len(hull)):
                if c in idx:
                    continue
                t = idx.copy(); t[k] = c
                a = area(hull[t])
                if a > best + 1e-6:
                    best = a; idx = t; imp = True
        if not imp:
            break
    return quad_order(hull[idx])


def detect(gray):
    h, w = gray.shape
    g = box_blur(box_blur(gray, 2), 2)
    t = otsu(g)
    best = None
    for bright in (True, False):
        mask = (g > t) if bright else (g <= t)
        n, lab, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), connectivity=4)
        if n <= 1:
            continue
        k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        comp = (lab == k).astype(np.uint8)
        # lấp lỗ
        inv = (1 - comp).astype(np.uint8)
        n2, lab2 = cv2.connectedComponents(inv, connectivity=4)
        border = set(np.unique(np.concatenate([lab2[0], lab2[-1], lab2[:, 0], lab2[:, -1]])))
        filled = comp.copy()
        for l in range(1, n2):
            if l not in border:
                filled[lab2 == l] = 1
        fa = filled.sum()
        if fa / (w * h) < 0.08:
            continue
        cs, _ = cv2.findContours(filled, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        pts = np.vstack([c.reshape(-1, 2) for c in cs]).astype(float) + 0.5
        hull = cv2.convexHull(pts.astype(np.float32)).reshape(-1, 2).astype(float)
        if len(hull) > 240:
            hull = hull[np.linspace(0, len(hull) - 1, 240).astype(int)]
        q = max_area_quad(hull)
        qa = area(q)
        if qa / (w * h) > 0.985:
            continue
        sol = min(1, fa / qa)
        conf = sol ** 3
        if best is None or conf > best[1]:
            best = (q, conf)
    return best


# ------------------------------------------------ MỚI: tinh chỉnh cạnh
def bilinear(img, x, y):
    h, w = img.shape
    x = min(max(x, 0), w - 1.001); y = min(max(y, 0), h - 1.001)
    x0, y0 = int(x), int(y); fx, fy = x - x0, y - y0
    a = img[y0, x0] + (img[y0, x0 + 1] - img[y0, x0]) * fx
    b = img[y0 + 1, x0] + (img[y0 + 1, x0 + 1] - img[y0 + 1, x0]) * fx
    return a + (b - a) * fy


def fit_line(pts):
    """Đường thẳng tổng bình phương vuông góc nhỏ nhất: (điểm, hướng)."""
    c = pts.mean(0)
    u, s, vt = np.linalg.svd(pts - c)
    return c, vt[0]


def refine_quad(gray, q):
    """gray: float32 độ phân giải đầy đủ. Trả về (quad mới, số cạnh tinh chỉnh)."""
    h, w = gray.shape
    diag = math.hypot(w, h)
    R = max(6.0, 0.012 * diag)
    cen = q.mean(0)
    lines = []
    for i in range(4):
        p0, p1 = q[i], q[(i + 1) % 4]
        L = np.linalg.norm(p1 - p0)
        t = (p1 - p0) / L
        n = np.array([-t[1], t[0]])
        if np.dot(cen - (p0 + p1) / 2, n) < 0:
            n = -n  # n hướng vào trong tờ giấy
        K = int(min(200, max(20, L / 8)))
        cand = {1: [], -1: []}
        score = {1: 0.0, -1: 0.0}
        for j in range(K):
            s = 0.08 + 0.84 * j / (K - 1)
            base = p0 + (p1 - p0) * s
            offs = np.arange(-R, R + 1, 1.0)
            prof = []
            for d in offs:
                c = base + n * d
                v = 0.0
                for tt in (-1.5, 0, 1.5):
                    cc = c + t * tt
                    v += bilinear(gray, cc[0], cc[1])
                prof.append(v / 3)
            prof = np.array(prof)
            grad = np.zeros_like(prof)
            grad[1:-1] = (prof[2:] - prof[:-2]) / 2
            for sign in (1, -1):
                gg = grad * sign
                k = int(np.argmax(gg[1:-1])) + 1
                if gg[k] <= 4:
                    continue
                # đỉnh parabol để lấy sub-pixel
                a, b, c3 = gg[k - 1], gg[k], gg[k + 1]
                den = a - 2 * b + c3
                sub = 0.5 * (a - c3) / den if abs(den) > 1e-9 else 0
                d = offs[k] + max(-0.5, min(0.5, sub))
                cand[sign].append(base + n * d)
                score[sign] += gg[k]
        sign = 1 if score[1] >= score[-1] else -1
        pts = np.array(cand[sign])
        if len(pts) < K * 0.4:
            lines.append(None)
            continue
        c, d = fit_line(pts)
        for _ in range(3):
            nn = np.array([-d[1], d[0]])
            res = np.abs((pts - c) @ nn)
            thr = max(1.0, 2.5 * np.median(res))
            keep = pts[res <= thr]
            if len(keep) < K * 0.35:
                break
            c, d = fit_line(keep)
        lines.append((c, d))

    def inter(l1, l2):
        (c1, d1), (c2, d2) = l1, l2
        A = np.array([d1, -d2]).T
        if abs(np.linalg.det(A)) < 1e-9:
            return None
        s = np.linalg.solve(A, c2 - c1)
        return c1 + d1 * s[0]

    out = q.copy()
    changed = 0
    for i in range(4):
        la, lb = lines[(i + 3) % 4], lines[i]  # cạnh trước góc i và cạnh sau
        if la is None or lb is None:
            continue
        p = inter(la, lb)
        if p is None or np.linalg.norm(p - q[i]) > 2.0 * R:
            continue
        out[i] = p
        changed += 1
    if area(out) < 0.5 * area(q):
        return q, 0
    return out, sum(l is not None for l in lines)


# ------------------------------------------- MỚI: tỷ lệ thật (Zhang & He)
PAPER = [("A4/A5", math.sqrt(2)), ("Letter", 11 / 8.5), ("Legal", 14 / 8.5)]


def true_aspect(q, img_w, img_h, f_hint=None):
    """Trả về (w/h thật, tiêu cự ước lượng hoặc None)."""
    u0, v0 = img_w / 2, img_h / 2
    tl, tr, br, bl = q
    m1 = np.array([tl[0] - u0, tl[1] - v0, 1.0])
    m2 = np.array([tr[0] - u0, tr[1] - v0, 1.0])
    m3 = np.array([bl[0] - u0, bl[1] - v0, 1.0])
    m4 = np.array([br[0] - u0, br[1] - v0, 1.0])
    k2 = np.dot(np.cross(m1, m4), m3) / np.dot(np.cross(m2, m4), m3)
    k3 = np.dot(np.cross(m1, m4), m2) / np.dot(np.cross(m3, m4), m2)
    n2 = k2 * m2 - m1
    n3 = k3 * m3 - m1
    L = max(img_w, img_h)
    fdef = f_hint or 0.72 * L
    f2 = None
    # Điều kiện tốt: CẢ HAI điểm tụ ở hữu hạn (cả 2 cặp cạnh đều hội tụ rõ).
    c2 = abs(n2[2]) * L / math.hypot(n2[0], n2[1])
    c3 = abs(n3[2]) * L / math.hypot(n3[0], n3[1])
    if f_hint is None and c2 > 0.08 and c3 > 0.08:
        f2c = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2])
        if f2c > 0:
            fc = math.sqrt(f2c)
            if 0.5 * L <= fc <= 1.6 * L:
                f2 = f2c
    f2u = f2 if f2 is not None else fdef ** 2
    num = (n2[0] ** 2 + n2[1] ** 2) / f2u + n2[2] ** 2
    den = (n3[0] ** 2 + n3[1] ** 2) / f2u + n3[2] ** 2
    return math.sqrt(num / den), (math.sqrt(f2) if f2 else None)


def snap(r):
    long = max(r, 1 / r)
    for name, pr in PAPER:
        if abs(long / pr - 1) <= 0.03:
            return (pr if r >= 1 else 1 / pr), name
    return r, None


def naive_aspect(q):
    tl, tr, br, bl = q
    w = max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl))
    h = max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr))
    return w / h


# ------------------------------------------------------------------ chạy
def run(case, f_hint=None):
    doc = make_doc()
    img, truth = camera_shot(doc, **case)
    H, W = img.shape[:2]
    gray_full = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    s = 720 / max(W, H)
    small = cv2.resize(gray_full, (round(W * s), round(H * s)), interpolation=cv2.INTER_AREA)
    det = detect(small)
    if det is None:
        print(case, "KHÔNG NHẬN DIỆN"); return None
    q0 = det[0] / s
    q1, nl = refine_quad(gray_full.astype(np.float32), q0)
    e0 = np.max(np.linalg.norm(q0 - truth, axis=1))
    e1 = np.max(np.linalg.norm(q1 - truth, axis=1))
    r_true = 0.210 / 0.297
    r_naive = naive_aspect(q1)
    r_est, f = true_aspect(q1, W, H, f_hint)
    r_snap, name = snap(r_est)
    print(f"{str(case):70s} góc: {e0:5.1f}px → {e1:4.2f}px  | tỷ lệ thật {r_true:.4f}  "
          f"cũ {r_naive:.4f} ({(r_naive/r_true-1)*100:+.1f}%)  mới {r_est:.4f} "
          f"({(r_est/r_true-1)*100:+.1f}%) f={f and round(f)}  snap={name}")
    return e1, r_est / r_true - 1, r_naive / r_true - 1


if __name__ == "__main__":
    cases = [
        dict(tilt_x=0, tilt_y=0, roll=3, dist=0.42),
        dict(tilt_x=20, tilt_y=0, roll=0, dist=0.42),
        dict(tilt_x=30, tilt_y=8, roll=-6, dist=0.45),
        dict(tilt_x=35, tilt_y=-12, roll=10, dist=0.47, shift=(0.01, -0.01)),
        dict(tilt_x=-25, tilt_y=15, roll=4, dist=0.44),
        dict(tilt_x=10, tilt_y=25, roll=-15, dist=0.46),
        dict(tilt_x=40, tilt_y=0, roll=2, dist=0.5),
    ]
    import sys
    fh = float(sys.argv[1]) if len(sys.argv) > 1 else None
    res = [run(c, fh) for c in cases]
    res = [r for r in res if r]
    print("\nmax sai số góc sau tinh chỉnh: %.2f px" % max(r[0] for r in res))
    print("max sai lệch tỷ lệ – mới: %.2f%%, cũ: %.2f%%" % (
        max(abs(r[1]) for r in res) * 100, max(abs(r[2]) for r in res) * 100))
