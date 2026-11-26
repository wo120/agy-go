import 'package:flutter/material.dart';

/// Original Precision Console design tokens for AGY Go.
/// Pure carbon/graphite layering with emerald-cyan accents and hairline borders.
class AgyColors {
  // Neutral carbon-slate surfaces (zero purple tint)
  static const bgCanvas = Color(0xFF090B0E);
  static const bgElevated = Color(0xFF101318);
  static const bgSubtle = Color(0xFF161B23);
  static const bgActive = Color(0xFF1E2530);
  static const bgDock = Color(0xFF0C0F14);
  static const bgCodeBlock = Color(0xFF07090C);

  // Crisp architectural hairlines
  static const borderHairline = Color(0xFF1E2430);
  static const borderStrong = Color(0xFF2B3444);
  static const borderAccent = Color(0x6614B8A6);

  // Typography ink hierarchy
  static const textPrimary = Color(0xFFF1F5F9);
  static const textSecondary = Color(0xFF94A3B8);
  static const textMuted = Color(0xFF64748B);
  static const textOnAccent = Color(0xFF041513);

  // Signature emerald-cyan brand accent
  static const accent = Color(0xFF14B8A6);
  static const accentBright = Color(0xFF2DD4BF);
  static const accentTint = Color(0x1F14B8A6);
  static const accentBubbleFill = Color(0xFF0E2524);
  static const accentBubbleBorder = Color(0x552DD4BF);

  // Semantic telemetry colors
  static const online = Color(0xFF22C55E);
  static const onlineTint = Color(0x1F22C55E);
  static const info = Color(0xFF38BDF8);
  static const infoTint = Color(0x1F38BDF8);
  static const warning = Color(0xFFF59E0B);
  static const warningTint = Color(0x1FF59E0B);
  static const danger = Color(0xFFEF4444);
  static const dangerTint = Color(0x1FEF4444);

  // Progress / gauge track
  static const barTrack = Color(0xFF212835);
}

/// Shared tabular-figures style helper for percentages, latency, and timestamps.
const List<FontFeature> kTabularFigures = [FontFeature.tabularFigures()];

ThemeData buildAgyTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AgyColors.bgCanvas,
    colorScheme: const ColorScheme.dark(
      primary: AgyColors.accent,
      onPrimary: AgyColors.textOnAccent,
      secondary: AgyColors.info,
      onSecondary: AgyColors.textOnAccent,
      surface: AgyColors.bgElevated,
      onSurface: AgyColors.textPrimary,
      error: AgyColors.danger,
      outline: AgyColors.borderHairline,
    ),
    dividerColor: AgyColors.borderHairline,
    appBarTheme: const AppBarTheme(
      backgroundColor: AgyColors.bgDock,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: AgyColors.textPrimary,
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AgyColors.textPrimary,
        letterSpacing: -0.2,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AgyColors.bgActive,
      contentTextStyle: const TextStyle(color: AgyColors.textPrimary, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AgyColors.borderStrong),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AgyColors.accent,
        foregroundColor: AgyColors.textOnAccent,
        disabledBackgroundColor: AgyColors.bgSubtle,
        disabledForegroundColor: AgyColors.textMuted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AgyColors.textPrimary,
        side: const BorderSide(color: AgyColors.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AgyColors.textOnAccent;
        return AgyColors.textSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return AgyColors.accent;
        return AgyColors.bgSubtle;
      }),
      trackOutlineColor: WidgetStateProperty.all(AgyColors.borderStrong),
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AgyColors.accent,
      inactiveTrackColor: AgyColors.barTrack,
      thumbColor: AgyColors.accentBright,
      overlayColor: AgyColors.accentTint,
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: AgyColors.textPrimary,
        letterSpacing: -0.3,
      ),
      titleMedium: TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        color: AgyColors.textPrimary,
        letterSpacing: -0.2,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.45,
        color: AgyColors.textSecondary,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        color: AgyColors.textMuted,
      ),
    ),
  );
}

/// Matte carbon canvas with an ultra-subtle top edge architectural luminance.
class AgyCanvas extends StatelessWidget {
  const AgyCanvas({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AgyColors.bgCanvas,
      child: child,
    );
  }
}

/// Sharp-edged matte console panel with 1px hairline border and optional left status rail.
class ConsolePanel extends StatelessWidget {
  const ConsolePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 12,
    this.backgroundColor = AgyColors.bgElevated,
    this.borderColor = AgyColors.borderHairline,
    this.accentStripeColor,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color backgroundColor;
  final Color borderColor;
  final Color? accentStripeColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    Widget content = Padding(padding: padding, child: child);
    if (accentStripeColor != null) {
      content = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 3,
              decoration: BoxDecoration(
                color: accentStripeColor,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(borderRadius),
                  bottomLeft: Radius.circular(borderRadius),
                ),
              ),
            ),
            Expanded(child: content),
          ],
        ),
      );
    }

    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: content,
      ),
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
        splashColor: AgyColors.accentTint,
        highlightColor: const Color(0x0DFFFFFF),
        child: box,
      ),
    );
  }
}

/// Compact industrial tag chip with hairline border.
class AgyTag extends StatelessWidget {
  const AgyTag({
    super.key,
    required this.label,
    this.icon,
    this.color = AgyColors.textSecondary,
    this.backgroundColor = AgyColors.bgSubtle,
    this.borderColor = AgyColors.borderHairline,
    this.monospace = false,
  });

  final String label;
  final IconData? icon;
  final Color color;
  final Color backgroundColor;
  final Color borderColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12.5, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                fontFamily: monospace ? 'monospace' : null,
                fontFeatures: kTabularFigures,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Square-rounded industrial icon button for headers and toolbars.
class AgyIconAction extends StatelessWidget {
  const AgyIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = AgyColors.textPrimary,
    this.size = 36,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AgyColors.bgElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AgyColors.borderHairline),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          splashColor: AgyColors.accentTint,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: 19, color: color),
          ),
        ),
      ),
    );
  }
}

/// Crisp telemetry status indicator dot with subtle ring.
class AgyStatusDot extends StatelessWidget {
  const AgyStatusDot({
    super.key,
    required this.color,
    this.size = 8,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size + 4,
      height: size + 4,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
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

/// Formats a chat message timestamp as HH:mm today, MM-dd HH:mm this year, or yyyy-MM-dd HH:mm.
String formatMessageTime(int unixSeconds, {DateTime? now}) {
  if (unixSeconds <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000).toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(dt.hour)}:${two(dt.minute)}';
  if (dt.year == ref.year && dt.month == ref.month && dt.day == ref.day) {
    return hm;
  }
  if (dt.year == ref.year) {
    return '${two(dt.month)}-${two(dt.day)} $hm';
  }
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} $hm';
}
