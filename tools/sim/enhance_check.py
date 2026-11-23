"""Port gọn DocumentEnhancer (Dart) + đường cong tông mới; đo độ sáng/đều nền, độ rõ chữ
và mức BẢO TOÀN NÉT MỰC (IoU mặt nạ mực so với tài liệu gốc)."""
import math, numpy as np, cv2, sys
sys.argv = sys.argv[:1]
import sim

def bg_model(rgb):
    h, w, _ = rgb.shape
    block = max(2, math.ceil(max(w, h) / 96)); gw, gh = math.ceil(w / block), math.ceil(h / block)
    grid = np.zeros((gh, gw, 3)); valid = np.zeros((gh, gw), bool)
    for by in range(gh):
        for bx in range(gw):
            b = rgb[by*block:(by+1)*block, bx*block:(bx+1)*block].reshape(-1, 3).astype(float)
            mx = b.max(1); mn = b.min(1); c = b[(mx - mn) <= 0.3 * mx + 12]
            if len(c) < 0.15 * len(b) or len(c) == 0: continue
            grid[by, bx] = np.percentile(c, 90, axis=0, method='lower'); valid[by, bx] = True
    lum = grid @ [0.299, 0.587, 0.114]
    paper = np.percentile(lum[valid], 90)
    valid &= lum >= paper * 0.35
    for _ in range(gw + gh):
        if valid.all(): break
        nv = valid.copy()
        for y, x in zip(*np.nonzero(~valid)):
            ys, xs = slice(max(0, y-1), y+2), slice(max(0, x-1), x+2)
            m = valid[ys, xs]
            if m.any(): grid[y, x] = grid[ys, xs][m].mean(0); nv[y, x] = True
        valid = nv
    for _ in range(2): grid = cv2.blur(grid, (5, 5), borderType=cv2.BORDER_REPLICATE)
    level = np.percentile(grid.reshape(-1, 3), 90, axis=0)
    grid = np.maximum(grid, level * 0.3)
    return cv2.resize(grid, (w, h), interpolation=cv2.INTER_LINEAR), level

def enhance(rgb, curve_new):
    bg, level = bg_model(rgb)
    x = rgb.astype(float)
    lum = (x @ [0.299, 0.587, 0.114]).ravel()[::7]
    black = min(np.percentile(lum, 1), 50)
    n = x * 250 / bg
    n = (n - black) * 250 / (250 - black)
    if curve_new:
        # Kéo giãn TUYẾN TÍNH: điểm trắng = mức giấy (trung vị độ sáng sau khử bóng),
        # điểm đen = phân vị 0,5% mực. Phép affine giữ nguyên vị trí "nửa đường" giữa
        # mực và giấy → biên nét chữ không dày/mỏng đi; chỉ nền giấy thành trắng tinh.
        l = (n @ [0.299, 0.587, 0.114]).ravel()[::5]
        white = np.percentile(l, 60) * 0.98
        blk = min(np.percentile(l, 0.5), white * 0.4)
        n = (n - blk) * 255 / (white - blk)
    return np.clip(np.round(n), 0, 255).astype(np.uint8)

def ink_mask(gray):
    return gray < 128

doc = sim.make_doc()
img, truth_q = sim.camera_shot(doc, tilt_x=0, tilt_y=0, roll=0, dist=0.42, img_w=1500, img_h=2000, f=1550)
# lấy đúng vùng tài liệu bằng homography đáp án (tách riêng phần làm sáng)
M = cv2.getPerspectiveTransform(np.float32(truth_q), np.float32([[0,0],[1050,0],[1050,1485],[0,1485]]))
shot = cv2.warpPerspective(img, M, (1050, 1485), flags=cv2.INTER_CUBIC)
rgb = shot[..., ::-1].copy()
truth = cv2.resize(cv2.cvtColor(doc, cv2.COLOR_BGR2GRAY), (1050, 1485), interpolation=cv2.INTER_AREA)
tm = ink_mask(truth)
inner = (slice(60, -60), slice(60, -60))
def stats(name, out):
    g = cv2.cvtColor(out, cv2.COLOR_RGB2GRAY) if out.ndim == 3 else out
    paper = g[inner][~tm[inner]]; ink = g[inner][tm[inner]]
    m = g < (paper.mean() + ink.mean()) / 2
    iou = (m & tm)[inner].sum() / (m | tm)[inner].sum()
    # màu dấu đỏ (BGR (40,40,200) trên doc): tâm vòng tròn bên phải
    ring = out[1250-80:1250-74, 750-3:750+3].reshape(-1, 3).mean(0) if out.ndim == 3 else None
    print(f"{name:22s} nền {paper.mean():5.1f}±{paper.std():4.1f} (min-max theo vùng {np.percentile(paper,2):.0f}-{np.percentile(paper,98):.0f}) | mực {ink.mean():5.1f} | tương phản {paper.mean()-ink.mean():5.1f} | IoU nét mực {iou:.3f}")
def mid_mask(g):
    p = np.percentile(g, 70); k = np.percentile(g, 3); return g < (p + k) / 2
bgm, _ = bg_model(rgb)
flat_ref = cv2.cvtColor(np.clip(rgb.astype(float) * 250 / bgm, 0, 255).astype(np.uint8), cv2.COLOR_RGB2GRAY)
ref_mask = mid_mask(flat_ref)
def keep(out):
    g = cv2.cvtColor(out, cv2.COLOR_RGB2GRAY); m = mid_mask(g)
    return (m & ref_mask)[inner].sum() / (m | ref_mask)[inner].sum()
stats("Ảnh chụp", rgb)
stats("Làm sáng (cũ)", enhance(rgb, False))
stats("Làm sáng + tông mới", enhance(rgb, True))
print("Nét mực trùng khớp với ảnh chụp (đã khử bóng): cũ %.4f | mới %.4f" % (keep(enhance(rgb, False)), keep(enhance(rgb, True))))
out = enhance(rgb, True)
cv2.imwrite('enh_compare.jpg', np.hstack([shot, out[..., ::-1]])[::2, ::2])
