import math, numpy as np, cv2, sys
sys.argv=sys.argv[:1]
import sim, curve, curl3d
def flat_and_coons(img, doc):
    H, W = img.shape[:2]; gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY); gf = gray.astype(np.float32)
    s = 720/max(W,H); small = cv2.resize(gray,(round(W*s),round(H*s)),interpolation=cv2.INTER_AREA)
    q0,bnd = curve.detect_with_boundary(small); q0/=s; bnd/=s
    q1,_ = sim.refine_quad(gf,q0)
    r,_ = sim.true_aspect(q1,W,H,1550.0); r,_ = sim.snap(r)
    ow=1050; oh=round(ow/r); zero={k:np.zeros(curve.NS) for k in ("top","right","bottom","left")}
    mx,my = curve.coons_map(q1,zero,ow,oh); flat = cv2.remap(gray,mx,my,cv2.INTER_LINEAR)
    R=max(6.0,0.012*math.hypot(W,H)); q=q1.copy(); init=curve.curves_from_boundary(bnd,q)
    for _ in range(3):
        coefs=curve.refine_curves(gf,q,init,R); q=curve.update_corners(q,coefs)
        tt=np.linspace(.03,.97,60)
        init={k:(tt,np.polyval(c,tt)-(np.polyval(c,0)+(np.polyval(c,1)-np.polyval(c,0))*tt)) for k,c in coefs.items()}
    devs=curve.sample_devs(curve.refine_curves(gf,q,init,R))
    mx,my=curve.coons_map(q,devs,ow,oh); coons=cv2.remap(gray,mx,my,cv2.INTER_LINEAR)
    return flat, coons
for mode in ["curl_bottom","book","wave","flat"]:
    curve.rng = np.random.default_rng(3); sim.rng = np.random.default_rng(3)
    doc = sim.make_doc(); 
    curve.rng = np.random.default_rng(5)
    img = curve.render_curved(doc, mode)
    truth = cv2.cvtColor(doc, cv2.COLOR_BGR2GRAY)
    flat, coons = flat_and_coons(img, doc)
    # mô hình 3D
    sim.rng = np.random.default_rng(3); curve.rng = np.random.default_rng(5)
    r3 = curl3d.run(mode)
    def m(o): return f"dọc {curve.misalign(o,truth):2d} ngang {curve.misalign_h(o,truth):2d}"
    line = f"{mode:12s} phẳng[{m(flat)}]  Coons[{m(coons)}]"
    if r3: line += f"  3D[{m(r3[1])}]"
    print(line)
