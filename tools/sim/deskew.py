import math, cv2, numpy as np, sys
sys.argv=['x']; import sim
def estimate_skew(gray):
    """Port sẽ viết sang Dart: thu nhỏ ~1000px, lấy điểm mực (tối hơn nền cục bộ),
    thử các góc, chọn góc làm phương sai hình chiếu theo hàng lớn nhất."""
    h, w = gray.shape
    s = 1000 / max(w, h)
    g = cv2.resize(gray, (round(w*s), round(h*s)), interpolation=cv2.INTER_AREA).astype(np.float32)
    bg = cv2.blur(g, (31, 31))
    ys, xs = np.nonzero(g < bg * 0.75)
    if len(xs) < 200: return 0.0, 0
    if len(xs) > 40000:
        idx = np.linspace(0, len(xs)-1, 40000).astype(int); xs, ys = xs[idx], ys[idx]
    cx, cy = g.shape[1]/2, g.shape[0]/2
    def score(a):
        t = math.radians(a)
        r = (ys-cy)*math.cos(t) - (xs-cx)*math.sin(t)
        hist = np.bincount((r - r.min()).astype(int))
        return float((hist.astype(np.float64)**2).sum())
    best = max(np.arange(-15, 15.01, 0.5), key=score)
    best = max(np.arange(best-0.5, best+0.501, 0.05), key=score)
    base = score(0.0)
    return float(best), score(best)/max(base,1)
doc = sim.make_doc()
for ang in [0, 1.2, -3.7, 6.5, -11]:
    H, W = doc.shape[:2]
    M = cv2.getRotationMatrix2D((W/2, H/2), ang, 1.0)
    rot = cv2.warpAffine(doc, M, (W, H), borderValue=(232,238,242))
    g = cv2.cvtColor(rot, cv2.COLOR_BGR2GRAY)
    est, gain = estimate_skew(g)
    print(f"xoay thật {ang:+6.2f}°  ước lượng {est:+6.2f}°  sai {est-ang:+.2f}°  gain {gain:.2f}")
