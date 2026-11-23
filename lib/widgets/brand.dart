import 'package:flutter/material.dart';

/// Nhận diện thương hiệu & bảng màu tươi trẻ dùng chung toàn app.
class Brand {
  static const appName = 'APP scan PDF';
  static const author = 'Đào Duy Thanh';
  static const sinceYear = 2026;

  // Bảng màu
  static const violet = Color(0xFF6C4DFF);
  static const blue = Color(0xFF2F80FF);
  static const teal = Color(0xFF00C2A8);
  static const coral = Color(0xFFFF6B6B);
  static const amber = Color(0xFFFFB020);
  static const ink = Color(0xFF1B1D2A);
  static const bg = Color(0xFFF5F6FB);

  static const mainGradient = LinearGradient(
    colors: [violet, blue],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const tealGradient = LinearGradient(
    colors: [Color(0xFF00C2A8), Color(0xFF00A3FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const coralGradient = LinearGradient(
    colors: [Color(0xFFFF7A59), Color(0xFFFF4D8D)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const amberGradient = LinearGradient(
    colors: [Color(0xFFFFB020), Color(0xFFFF7A00)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: violet,
      primary: violet,
      secondary: teal,
      tertiary: coral,
      surface: Colors.white,
    );
    final radius = BorderRadius.circular(16);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: TextStyle(color: ink, fontSize: 20, fontWeight: FontWeight.w800),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: radius),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 54),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 54),
          shape: RoundedRectangleBorder(borderRadius: radius),
          side: const BorderSide(color: violet, width: 1.5),
          foregroundColor: violet,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        selectedColor: violet.withValues(alpha: 0.15),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide(color: Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(
            borderRadius: radius, borderSide: const BorderSide(color: violet, width: 2)),
      ),
      sliderTheme: const SliderThemeData(trackHeight: 5),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: violet.withValues(alpha: 0.15),
        labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
    );
  }
}

/// Chân app: tên app và tên tác giả in đậm, © since 2026.
class BrandFooter extends StatelessWidget {
  final bool onDark;
  const BrandFooter({super.key, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final base = onDark ? Colors.white70 : const Color(0xFF6B6F80);
    final strong = onDark ? Colors.white : Brand.ink;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      child: Text.rich(
        TextSpan(
          style: TextStyle(color: base, fontSize: 13, height: 1.5),
          children: [
            TextSpan(
                text: Brand.appName,
                style: TextStyle(fontWeight: FontWeight.w900, color: strong)),
            const TextSpan(text: '  •  App làm bởi '),
            TextSpan(
                text: Brand.author, style: TextStyle(fontWeight: FontWeight.w900, color: strong)),
            const TextSpan(text: '\n© since ${Brand.sinceYear}'),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// Nút thao tác lớn nền gradient (rõ nét, dễ bấm một tay).
class GradientButton extends StatelessWidget {
  final String label;
  final String? subtitle;
  final IconData icon;
  final Gradient gradient;
  final VoidCallback? onTap;
  final double height;

  const GradientButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.gradient = Brand.mainGradient,
    this.height = 92,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.5 : 1,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: gradient.colors.first.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: Colors.white, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.9), fontSize: 13)),
                    ],
                  ),
                ),
                const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 18),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ô thao tác vuông có biểu tượng màu (lưới chức năng ở trang chủ).
class ActionTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final Gradient gradient;
  final VoidCallback? onTap;
  const ActionTile({
    super.key,
    required this.label,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(16)),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 10),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Brand.ink)),
          ]),
        ),
      ),
    );
  }
}

/// Đầu trang gradient với logo + tên app đậm.
class BrandHeader extends StatelessWidget {
  final Widget? trailing;
  const BrandHeader({super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 14, 12, 26),
      decoration: const BoxDecoration(
        gradient: Brand.mainGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      child: Row(children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.document_scanner_rounded, color: Brand.violet, size: 30),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Brand.appName,
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
            Text('Scan tài liệu – xuất PDF sắc nét',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}
