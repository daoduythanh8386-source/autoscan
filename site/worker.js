/* APP scan PDF – Web Worker: xử lý ảnh nặng ngoài luồng giao diện. */
importScripts('cv.js');

self.onmessage = (e) => {
  const { id, op } = e.data;
  try {
    let result, transfer = [];
    switch (op) {
      case 'detect': {
        // khung camera: gray nhỏ
        const r = CV.detect(e.data.gray, e.data.w, e.data.h);
        result = { quad: r.quad, reliable: r.reliable, conf: r.conf, issues: r.issues, sharp: CV.lapVar(e.data.gray, e.data.w, e.data.h) };
        break;
      }
      case 'ingest': {
        // Ảnh mới: phân tích độ phân giải đầy đủ + ảnh thu nhỏ đã xử lý
        const a = CV.analyze(e.data.rgba, e.data.w, e.data.h, null);
        const params = Object.assign({ corners: a.corners, dewarp: a.dewarp, fineRotation: a.fineRotation, mode: e.data.mode || 'document', paper: 'auto', rotation: 0 }, {});
        const sm = CV.downRGBA(e.data.rgba, e.data.w, e.data.h, 420);
        const t = CV.render(sm.rgba, sm.w, sm.h, params, sm.s, null, false);
        result = { analysis: a, params, thumb: { rgba: t.rgba, w: t.w, h: t.h } };
        transfer = [t.rgba.buffer];
        break;
      }
      case 'thumb': {
        const sm = CV.downRGBA(e.data.rgba, e.data.w, e.data.h, 420);
        const t = CV.render(sm.rgba, sm.w, sm.h, e.data.params, sm.s, null, false);
        result = { rgba: t.rgba, w: t.w, h: t.h };
        transfer = [t.rgba.buffer];
        break;
      }
      case 'analyze': {
        result = CV.analyze(e.data.rgba, e.data.w, e.data.h, e.data.f35 || null);
        break;
      }
      case 'render': {
        const r = CV.render(e.data.rgba, e.data.w, e.data.h, e.data.params, e.data.scale || 1, e.data.f35 || null, !!e.data.bicubic);
        result = { w: r.w, h: r.h, rgba: r.rgba };
        transfer = [r.rgba.buffer];
        break;
      }
      case 'aspect': {
        const p = e.data.params;
        if (!p.corners) { result = null; break; }
        const m = CV.makeModel(p.dewarp);
        result = m ? CV.snapAspect(m.aspect, p.paper || 'auto') : CV.estimateAspect(p.corners, e.data.w, e.data.h, null, p.paper || 'auto');
        break;
      }
      case 'snap':
        result = CV.snapEdges(e.data.rgba, e.data.w, e.data.h, e.data.quad);
        break;
      case 'dewarp':
        result = CV.dewarpWith(e.data.rgba, e.data.w, e.data.h, e.data.quad, null);
        break;
      case 'straighten': {
        const p = Object.assign({}, e.data.params, { fineRotation: 0, mode: 'original', shadow: 0, brightness: 0, contrast: 0, sharpness: 0, warmth: 0 });
        const r = CV.render(e.data.rgba, e.data.w, e.data.h, p, e.data.scale || 1, null, false);
        const sk = CV.estimateSkew(CV.toGray(r.rgba, r.w, r.h), r.w, r.h);
        result = sk.reliable ? sk.correction : 0;
        break;
      }
      default:
        throw new Error('op không hỗ trợ: ' + op);
    }
    self.postMessage({ id, result }, transfer);
  } catch (err) {
    self.postMessage({ id, error: String(err && err.message || err) });
  }
};
