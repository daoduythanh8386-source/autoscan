import json, sys, numpy as np, cv2
sys.argv=sys.argv[:1]
import sim, curve
cases=[]
def save(name, img, doc, truth=None):
    rgba=cv2.cvtColor(img, cv2.COLOR_BGR2RGBA); h,w=rgba.shape[:2]
    rgba.tofile(f'/tmp/jt/{name}.rgba')
    cv2.imwrite(f'/tmp/jt/{name}_truth.png', cv2.cvtColor(doc, cv2.COLOR_BGR2GRAY))
    cases.append(dict(name=name,w=w,h=h,truth=None if truth is None else truth.tolist()))
for i,c in enumerate([dict(tilt_x=30,tilt_y=8,roll=-6,dist=0.45), dict(tilt_x=40,tilt_y=0,roll=2,dist=0.5)]):
    sim.rng=np.random.default_rng(10+i); doc=sim.make_doc()
    img,tq=sim.camera_shot(doc, img_w=1500, img_h=2000, f=1550, **c)
    save(f'flat{i}', img, doc, tq)
for m in ['curl_bottom','book','wave']:
    sim.rng=np.random.default_rng(3); doc=sim.make_doc(); curve.rng=np.random.default_rng(5)
    save(m, curve.render_curved(doc, m), doc)
json.dump(cases, open('/tmp/jt/cases.json','w'))
print(len(cases),'cases')
