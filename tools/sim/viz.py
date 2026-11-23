import sys, math, cv2, numpy as np
sys.argv=['x']
import sim
def render(case, out):
    doc = sim.make_doc()
    img, truth = sim.camera_shot(doc, **case)
    H, W = img.shape[:2]
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    s = 720 / max(W, H)
    small = cv2.resize(g, (round(W*s), round(H*s)), interpolation=cv2.INTER_AREA)
    q0 = sim.detect(small)[0] / s
    q1, _ = sim.refine_quad(g.astype(np.float32), q0)
    def warp(q, w, h):
        M = cv2.getPerspectiveTransform(np.float32(q), np.float32([[0,0],[w,0],[w,h],[0,h]]))
        return cv2.warpPerspective(img, M, (int(w), int(h)), flags=cv2.INTER_CUBIC)
    tl,tr,br,bl = q0
    wo = max(np.linalg.norm(tr-tl), np.linalg.norm(br-bl)); ho = max(np.linalg.norm(bl-tl), np.linalg.norm(br-tr))
    old = warp(q0, wo, ho)
    r,_ = sim.true_aspect(q1, W, H); r,_ = sim.snap(r)
    tl,tr,br,bl = q1
    wm = max(np.linalg.norm(tr-tl), np.linalg.norm(br-bl)); hm = max(np.linalg.norm(bl-tl), np.linalg.norm(br-tr))
    wn = max(wm, hm*r); hn = wn / r
    new = warp(q1, wn, hn)
    th = 900
    def fit(a): return cv2.resize(a, (round(a.shape[1]*th/a.shape[0]), th), interpolation=cv2.INTER_AREA)
    shot = img.copy()
    cv2.polylines(shot, [np.int32(q1)], True, (0,220,0), 12)
    pad = np.full((th, 30, 3), 255, np.uint8)
    panel = np.hstack([fit(shot), pad, fit(old), pad, fit(new)])
    bar = np.full((70, panel.shape[1], 3), 255, np.uint8)
    for x, t in [(10, "Anh chup (nghieng)"), (fit(shot).shape[1]+40, "Truoc: ty le sai (bi bop)"), (fit(shot).shape[1]+fit(old).shape[1]+70, "Sau: dung ty le A4")]:
        cv2.putText(bar, t, (x, 48), cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0,0,0), 2)
    cv2.imwrite(out, np.vstack([bar, panel]), [cv2.IMWRITE_JPEG_QUALITY, 88])
render(dict(tilt_x=40, tilt_y=0, roll=2, dist=0.5), 'compare_tilt40.jpg')
print('ok')
