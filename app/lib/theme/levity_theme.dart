import 'dart:ui';

import 'package:flutter/material.dart';

/// Design tokens matching the dark translucent starlight aesthetic.
class LevityColors {
  static const bgDeep = Color(0xFF0A0B14);
  static const bgMid = Color(0xFF151229);
  static const bgAccentGlow = Color(0xFF231942);

  static const cardFill = Color(0xB81A1C2E);
  static const cardBorder = Color(0x1FFFFFFF);
  static const capsuleFill = Color(0xAA23253D);
  static const capsuleActive = Color(0xFF363A59);

  static const textPrimary = Color(0xFFF3F4F8);
  static const textSecondary = Color(0xFF9EA4BA);
  static const textMuted = Color(0xFF727892);

  static const greenDirect = Color(0xFF34D399);
  static const blueUnread = Color(0xFF60A5FA);
  static const orangeWarning = Color(0xFFF59E0B);
  static const purpleSubagent = Color(0xFFA78BFA);
  static const slateArtifact = Color(0xFF94A3B8);
  static const barTrack = Color(0x2EFFFFFF);
}

ThemeData buildLevityTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: LevityColors.bgDeep,
    colorScheme: const ColorScheme.dark(
      primary: LevityColors.purpleSubagent,
      secondary: LevityColors.blueUnread,
      surface: Color(0xFF161829),
      error: Color(0xFFF87171),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: LevityColors.textPrimary,
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: LevityColors.textPrimary),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: LevityColors.textPrimary),
      bodyMedium: TextStyle(fontSize: 14, height: 1.42, color: LevityColors.textSecondary),
      bodySmall: TextStyle(fontSize: 12, color: LevityColors.textMuted),
    ),
  );
}

class LevityBackground extends StatelessWidget {
  const LevityBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.15, -0.75),
          radius: 1.35,
          colors: [
            LevityColors.bgAccentGlow,
            LevityColors.bgMid,
            LevityColors.bgDeep,
          ],
          stops: [0.0, 0.45, 1.0],
        ),
      ),
      child: child,
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 20,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: LevityColors.cardFill,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: LevityColors.cardBorder, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );

    if (onTap == null && onLongPress == null) {
      return box;
    }
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(borderRadius),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(borderRadius),
        splashColor: const Color(0x1FA78BFA),
        highlightColor: const Color(0x14FFFFFF),
        child: box,
      ),
    );
  }
}

class GlassCapsule extends StatelessWidget {
  const GlassCapsule({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: LevityColors.capsuleFill,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: LevityColors.cardBorder, width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Formats reset countdown matching "1h 9m 后重置" / "4d 10h 后重置" / "满额".
String formatResetCountdown(int? resetAtUnix, int remainingPct, {DateTime? now}) {
  if (resetAtUnix == null || resetAtUnix <= 0) {
    return '满额';
  }
  final cur = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final diff = resetAtUnix - cur;
  if (diff <= 60) {
    return '即将重置';
  }
  final days = diff ~/ 86400;
  final hours = (diff % 86400) ~/ 3600;
  final mins = (diff % 3600) ~/ 60;
  if (days > 0) {
    return '${days}d ${hours}h 后重置';
  }
  if (hours > 0) {
    return '${hours}h ${mins}m 后重置';
  }
  return '${mins}m 后重置';
}

/// Formats conversation timestamp as HH:mm today or MM-dd on earlier days.
String formatSessionTime(int unixSeconds, {DateTime? now}) {
  if (unixSeconds <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  if (dt.year == ref.year && dt.month == ref.month && dt.day == ref.day) {
    return '${two(dt.hour)}:${two(dt.minute)}';
  }
  return '${two(dt.month)}-${two(dt.day)}';
}
