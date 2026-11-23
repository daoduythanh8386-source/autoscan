import 'dart:math' as math;
import 'dart:typed_data';

import '../../models/edit_params.dart';

/// Tăng cường ảnh tài liệu, thích ứng theo từng ảnh (mục 8–9 đặc tả).
///
/// Nguyên tắc bảo toàn nội dung:
/// - Chỉ dùng các phép biến đổi điểm ảnh/cục bộ cổ điển, KHÔNG dùng AI sinh ảnh.
/// - Cân bằng sáng bằng cách chia cho "nền giấy" ước lượng (max-filter + blur),
///   tính theo từng kênh → khử ám vàng nhưng giữ màu mực, dấu đỏ, chữ ký xanh.
/// - Làm nét có giới hạn biên độ để không tạo viền giả.
class DocumentEnhancer {
  /// [rgb] 3 kênh, kích thước w x h. Trả về buffer mới (không sửa đầu vào).
  Uint8List apply(Uint8List rgb, int w, int h, EditParams p) {
    var out = Uint8List.fromList(rgb);
    final needsFlatten = p.mode != ColorMode.original || p.shadowReduction > 0.01;
    if (needsFlatten) {
      final bg = BackgroundModel.estimate(rgb, w, h);
      out = _flatten(rgb, w, h, bg, p);
    }
    switch (p.mode) {
      case ColorMode.original:
      case ColorMode.colorDocument:
        break;
      case ColorMode.grayscale:
        out = _toGray3(out);
        break;
      case ColorMode.blackWhite:
        out = _sauvola(_toGray3(out), w, h);
        break;
    }
    out = _applyLut(out, p);
    if (p.sharpness > 0.01 && p.mode != ColorMode.blackWhite) {
      out = _unsharp(out, w, h, p.sharpness);
    }
    return out;
  }

  Uint8List _flatten(Uint8List src, int w, int h, BackgroundModel bg, EditParams p) {
    final out = Uint8List(src.length);
    final whiten = p.mode != ColorMode.original;
    final s = whiten ? 1.0 : p.shadowReduction.clamp(0.0, 1.0);
    const target = 250.0;
    // Chế độ tài liệu: KÉO GIÃN TUYẾN TÍNH sau khi khử bóng.
    //   điểm trắng = mức giấy (phân vị 60% độ sáng) × 0,98  → giấy trắng tinh
    //   điểm đen  = phân vị 0,5% (mực đậm nhất)              → mực đen rõ
    // Phép affine dùng CHUNG cho mọi điểm ảnh nên thứ tự sáng/tối và vị trí biên
    // nét chữ được giữ nguyên: nét không dày lên, không mỏng đi, không vẽ thêm.
    var white = 255.0, black = 0.0;
    if (whiten) {
      final hist = List<int>.filled(512, 0);
      var n = 0;
      for (var i = 0; i < w * h; i += 5) {
        final b = bg.sample(i % w, i ~/ w, w, h);
        final j = i * 3;
        final l = 0.299 * src[j] * target / b[0] +
            0.587 * src[j + 1] * target / b[1] +
            0.114 * src[j + 2] * target / b[2];
        hist[l.round().clamp(0, 511)]++;
        n++;
      }
      double pct(double q) {
        var acc = 0;
        for (var v = 0; v < 512; v++) {
          acc += hist[v];
          if (acc >= n * q) return v.toDouble();
        }
        return 511;
      }

      white = math.max(120.0, pct(0.60) * 0.98);
      black = math.min(pct(0.005), white * 0.4);
    }
    final gain = 255 / math.max(1.0, white - black);
    var o = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final b = bg.sample(x, y, w, h);
        for (var c = 0; c < 3; c++) {
          final v = src[o].toDouble();
          // Màu gốc: đưa nền về mức trung bình của giấy (giữ tông giấy);
          // Tài liệu: đưa nền về trắng.
          final ref = whiten ? target : bg.paperLevel[c];
          var nv = v * ref / b[c];
          if (whiten) nv = (nv - black) * gain;
          final r = v + (nv - v) * s;
          out[o++] = r < 0 ? 0 : (r > 255 ? 255 : r.round());
        }
      }
    }
    return out;
  }

  static int _luma(int r, int g, int b) => (r * 299 + g * 587 + b * 114) ~/ 1000;

  Uint8List _toGray3(Uint8List rgb) {
    final out = Uint8List(rgb.length);
    for (var i = 0; i < rgb.length; i += 3) {
      final l = _luma(rgb[i], rgb[i + 1], rgb[i + 2]);
      out[i] = l;
      out[i + 1] = l;
      out[i + 2] = l;
    }
    return out;
  }

  /// Ngưỡng thích ứng Sauvola trên ảnh xám (3 kênh bằng nhau).
  /// k nhỏ để giữ nét mảnh; cửa sổ tỉ lệ với độ phân giải.
  Uint8List _sauvola(Uint8List gray3, int w, int h) {
    final n = w * h;
    final integ = Float64List((w + 1) * (h + 1));
    final integSq = Float64List((w + 1) * (h + 1));
    for (var y = 0; y < h; y++) {
      var rs = 0.0, rsq = 0.0;
      for (var x = 0; x < w; x++) {
        final v = gray3[(y * w + x) * 3].toDouble();
        rs += v;
        rsq += v * v;
        final idx = (y + 1) * (w + 1) + x + 1;
        integ[idx] = integ[idx - (w + 1)] + rs;
        integSq[idx] = integSq[idx - (w + 1)] + rsq;
      }
    }
    final r = math.max(7, math.min(w, h) ~/ 60);
    const k = 0.15, range = 128.0;
    final out = Uint8List(n * 3);
    for (var y = 0; y < h; y++) {
      final y0 = math.max(0, y - r), y1 = math.min(h, y + r + 1);
      for (var x = 0; x < w; x++) {
        final x0 = math.max(0, x - r), x1 = math.min(w, x + r + 1);
        final a = y0 * (w + 1) + x0, b = y0 * (w + 1) + x1;
        final c = y1 * (w + 1) + x0, d = y1 * (w + 1) + x1;
        final cnt = (x1 - x0) * (y1 - y0);
        final mean = (integ[d] - integ[b] - integ[c] + integ[a]) / cnt;
        final sq = (integSq[d] - integSq[b] - integSq[c] + integSq[a]) / cnt;
        final sd = math.sqrt(math.max(0, sq - mean * mean));
        final t = mean * (1 + k * (sd / range - 1));
        final i = (y * w + x) * 3;
        final v = gray3[i] > t ? 255 : 0;
        out[i] = v;
        out[i + 1] = v;
        out[i + 2] = v;
      }
    }
    return out;
  }

  Uint8List _applyLut(Uint8List rgb, EditParams p) {
    if (p.brightness.abs() < 1e-3 && p.contrast.abs() < 1e-3 && p.warmth.abs() < 1e-3) {
      return rgb;
    }
    final luts = List.generate(3, (c) {
      final lut = Uint8List(256);
      final wb = c == 0 ? p.warmth * 18 : (c == 2 ? -p.warmth * 18 : 0);
      for (var v = 0; v < 256; v++) {
        var x = v + p.brightness * 60 + wb;
        x = (x - 128) * (1 + p.contrast) + 128;
        lut[v] = x.round().clamp(0, 255);
      }
      return lut;
    });
    final out = Uint8List(rgb.length);
    for (var i = 0; i < rgb.length; i += 3) {
      out[i] = luts[0][rgb[i]];
      out[i + 1] = luts[1][rgb[i + 1]];
      out[i + 2] = luts[2][rgb[i + 2]];
    }
    return out;
  }

  /// Unsharp mask 3x3, biên độ tối đa ±36 mức để chống halo.
  Uint8List _unsharp(Uint8List rgb, int w, int h, double amount) {
    final a = amount.clamp(0.0, 1.0) * 0.8;
    final out = Uint8List(rgb.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        for (var c = 0; c < 3; c++) {
          final i = (y * w + x) * 3 + c;
          if (x == 0 || y == 0 || x == w - 1 || y == h - 1) {
            out[i] = rgb[i];
            continue;
          }
          var sum = 0;
          for (var dy = -1; dy <= 1; dy++) {
            final row = (y + dy) * w;
            for (var dx = -1; dx <= 1; dx++) {
              sum += rgb[(row + x + dx) * 3 + c];
            }
          }
          var d = (rgb[i] - sum / 9) * a;
          if (d > 36) d = 36;
          if (d < -36) d = -36;
          out[i] = (rgb[i] + d).round().clamp(0, 255);
        }
      }
    }
    return out;
  }
}

/// Mô hình nền giấy độ phân giải thấp, nội suy song tuyến khi lấy mẫu.
class BackgroundModel {
  final int gw, gh;
  final Float64List data; // gw*gh*3
  final List<double> paperLevel;

  BackgroundModel(this.gw, this.gh, this.data, this.paperLevel);

  /// Ước lượng nền giấy theo khối, CHỈ dùng các điểm ảnh "giống giấy"
  /// (độ bão hoà thấp). Nhờ vậy dấu đỏ, chữ ký xanh, vùng tô màu không bị coi là
  /// nền → không bị tẩy trắng. Khối không đủ điểm giấy (hoặc quá tối – ô đen đặc)
  /// được nội suy từ các khối lân cận.
  static BackgroundModel estimate(Uint8List rgb, int w, int h) {
    final block = math.max(2, (math.max(w, h) / 96).ceil());
    final gw = (w / block).ceil(), gh = (h / block).ceil();
    final grid = Float64List(gw * gh * 3);
    final valid = Uint8List(gw * gh);
    final hist = List.generate(3, (_) => List<int>.filled(256, 0));
    for (var by = 0; by < gh; by++) {
      for (var bx = 0; bx < gw; bx++) {
        final x0 = bx * block, y0 = by * block;
        final x1 = math.min(w, x0 + block), y1 = math.min(h, y0 + block);
        for (final hh in hist) {
          hh.fillRange(0, 256, 0);
        }
        var cand = 0;
        final total = (x1 - x0) * (y1 - y0);
        for (var y = y0; y < y1; y++) {
          for (var x = x0; x < x1; x++) {
            final i = (y * w + x) * 3;
            final r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
            final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
            if (mx - mn <= 0.3 * mx + 12) {
              hist[0][r]++;
              hist[1][g]++;
              hist[2][b]++;
              cand++;
            }
          }
        }
        if (cand < total * 0.15 || cand == 0) continue;
        final k = by * gw + bx;
        valid[k] = 1;
        for (var c = 0; c < 3; c++) {
          // Phân vị 90% của điểm giấy: bỏ qua chữ (tối) và nhiễu sáng.
          var acc = 0, v = 255;
          for (var t = 255; t >= 0; t--) {
            acc += hist[c][t];
            if (acc >= cand * 0.1) {
              v = t;
              break;
            }
          }
          grid[k * 3 + c] = v.toDouble();
        }
      }
    }
    // Mức giấy tham chiếu = phân vị 90% độ sáng các khối hợp lệ.
    final lums = <double>[];
    for (var k = 0; k < gw * gh; k++) {
      if (valid[k] == 1) lums.add(_l(grid, k));
    }
    final level = List<double>.filled(3, 255);
    if (lums.isEmpty) {
      grid.fillRange(0, grid.length, 255);
      return BackgroundModel(gw, gh, grid, level);
    }
    lums.sort();
    final paperLum = lums[(lums.length * 0.9).floor().clamp(0, lums.length - 1)];
    // Khối quá tối so với giấy (ô đen đặc, ảnh) → coi là thiếu dữ liệu nền.
    for (var k = 0; k < gw * gh; k++) {
      if (valid[k] == 1 && _l(grid, k) < paperLum * 0.35) valid[k] = 0;
    }
    _inpaint(grid, valid, gw, gh);
    final smooth = _blur(_blur(grid, gw, gh), gw, gh);
    for (var c = 0; c < 3; c++) {
      final vals = [for (var i = c; i < smooth.length; i += 3) smooth[i]]..sort();
      level[c] = math.max(1.0, vals[(vals.length * 0.9).floor().clamp(0, vals.length - 1)]);
      final floor = level[c] * 0.3;
      for (var i = c; i < smooth.length; i += 3) {
        if (smooth[i] < floor) smooth[i] = floor;
      }
    }
    return BackgroundModel(gw, gh, smooth, level);
  }

  static double _l(Float64List g, int k) =>
      g[k * 3] * 0.299 + g[k * 3 + 1] * 0.587 + g[k * 3 + 2] * 0.114;

  /// Lấp khối thiếu bằng trung bình các khối hợp lệ lân cận, lan dần từ ngoài vào.
  static void _inpaint(Float64List g, Uint8List valid, int gw, int gh) {
    var missing = valid.where((v) => v == 0).length;
    var guard = gw + gh + 2;
    while (missing > 0 && guard-- > 0) {
      final next = Uint8List.fromList(valid);
      for (var y = 0; y < gh; y++) {
        for (var x = 0; x < gw; x++) {
          final k = y * gw + x;
          if (valid[k] == 1) continue;
          var n = 0;
          final sum = [0.0, 0.0, 0.0];
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              final xx = x + dx, yy = y + dy;
              if (xx < 0 || yy < 0 || xx >= gw || yy >= gh) continue;
              final kk = yy * gw + xx;
              if (valid[kk] == 0) continue;
              n++;
              for (var c = 0; c < 3; c++) {
                sum[c] += g[kk * 3 + c];
              }
            }
          }
          if (n > 0) {
            for (var c = 0; c < 3; c++) {
              g[k * 3 + c] = sum[c] / n;
            }
            next[k] = 1;
            missing--;
          }
        }
      }
      valid.setAll(0, next);
    }
  }

  static Float64List _blur(Float64List g, int gw, int gh) {
    final out = Float64List(g.length);
    for (var y = 0; y < gh; y++) {
      for (var x = 0; x < gw; x++) {
        for (var c = 0; c < 3; c++) {
          var s = 0.0;
          var n = 0;
          for (var dy = -2; dy <= 2; dy++) {
            final yy = (y + dy).clamp(0, gh - 1);
            for (var dx = -2; dx <= 2; dx++) {
              final xx = (x + dx).clamp(0, gw - 1);
              s += g[(yy * gw + xx) * 3 + c];
              n++;
            }
          }
          out[(y * gw + x) * 3 + c] = s / n;
        }
      }
    }
    return out;
  }

  final List<double> _tmp = List<double>.filled(3, 0);

  /// Lấy giá trị nền tại pixel (x, y) của ảnh w x h. Trả về buffer dùng chung.
  List<double> sample(int x, int y, int w, int h) {
    final fx = ((x + 0.5) / w * gw - 0.5).clamp(0.0, gw - 1.0);
    final fy = ((y + 0.5) / h * gh - 0.5).clamp(0.0, gh - 1.0);
    final x0 = fx.floor(), y0 = fy.floor();
    final x1 = math.min(gw - 1, x0 + 1), y1 = math.min(gh - 1, y0 + 1);
    final ax = fx - x0, ay = fy - y0;
    for (var c = 0; c < 3; c++) {
      final a = data[(y0 * gw + x0) * 3 + c], b = data[(y0 * gw + x1) * 3 + c];
      final d = data[(y1 * gw + x0) * 3 + c], e = data[(y1 * gw + x1) * 3 + c];
      final top = a + (b - a) * ax, bot = d + (e - d) * ax;
      _tmp[c] = math.max(1.0, top + (bot - top) * ay);
    }
    return _tmp;
  }

  /// Tỷ lệ nền tối nhất / sáng nhất – dùng phát hiện bóng đổ.
  double get unevenness {
    var mn = double.infinity, mx = 0.0;
    for (var i = 0; i < data.length; i += 3) {
      final l = data[i] * 0.299 + data[i + 1] * 0.587 + data[i + 2] * 0.114;
      mn = math.min(mn, l);
      mx = math.max(mx, l);
    }
    return mx == 0 ? 1 : mn / mx;
  }
}
