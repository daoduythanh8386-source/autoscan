import math, numpy as np, cv2, sys
sys.argv=sys.argv[:1]
import sim, curve, curl3d, compare_all as ca
rows=[]
for mode, label in [("curl_bottom","Mep duoi bi quan"),("book","Gay sach cong"),("wave","Giay gon song")]:
    sim.rng=np.random.default_rng(3); doc=sim.make_doc(); curve.rng=np.random.default_rng(5)
    img=curve.render_curved(doc, mode)
    flat, coons = ca.flat_and_coons(img, doc)
    curve.rng=np.random.default_rng(5); sim.make_doc=lambda d=doc: d
    r=curl3d.run(mode)
    best = r[1] if r else coons
    th=640
    def fit(a):
        if a.ndim==2: a=cv2.cvtColor(a,cv2.COLOR_GRAY2BGR)
        return cv2.resize(a,(round(a.shape[1]*th/a.shape[0]),th),interpolation=cv2.INTER_AREA)
    def grid(a):
        a=a.copy(); h,w=a.shape[:2]
        for i in range(1,12): cv2.line(a,(0,h*i//12),(w,h*i//12),(255,180,0),1)
        return a
    pad=np.full((th,20,3),255,np.uint8)
    panel=np.hstack([fit(img),pad,grid(fit(flat)),pad,grid(fit(best))])
    bar=np.full((50,panel.shape[1],3),255,np.uint8)
    x1=fit(img).shape[1]+26; x2=x1+fit(flat).shape[1]+20
    for x,t in [(6,label),(x1,"Chi nan phang"),(x2,"Nan cong (moi)")]:
        cv2.putText(bar,t,(x,36),cv2.FONT_HERSHEY_SIMPLEX,0.95,(0,0,0),2)
    rows.append(np.vstack([bar,panel]))
W=max(r.shape[1] for r in rows)
rows=[np.hstack([r,np.full((r.shape[0],W-r.shape[1],3),255,np.uint8)]) for r in rows]
cv2.imwrite('curve_compare.jpg',np.vstack(rows),[cv2.IMWRITE_JPEG_QUALITY,85])
print("ok")
