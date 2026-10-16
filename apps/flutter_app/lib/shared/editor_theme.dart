import 'package:flutter/material.dart';

abstract final class EditorColors {
  static const shell = Color(0xfff3f4f8);
  static const canvas = Color(0xffe9ecf2);
  static const surface = Colors.white;
  static const subtle = Color(0xfff8f9fc);
  static const hover = Color(0xffeef0f7);
  static const text = Color(0xff202430);
  static const secondary = Color(0xff4e566d);
  static const muted = Color(0xff7b839a);
  static const border = Color(0xffe5e8f0);
  static const focus = Color(0xff4c5cff);
  static const selection = Color(0x124c5cff);
  static const shadow = Color(0x0c242428);
  static const success = Color(0xff179553);
  static const warning = Color(0xff966f31);
}

Duration motionDuration(BuildContext context, [int milliseconds = 160]) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : Duration(milliseconds: milliseconds);

Widget motionLayout(Widget? current, List<Widget> previous) => Stack(
  alignment: Alignment.center,
  children: [
    for (final child in previous)
      ExcludeFocus(
        child: IgnorePointer(child: ExcludeSemantics(child: child)),
      ),
    ?current,
  ],
);

ThemeData editorTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'FolinqSans',
  fontFamilyFallback: const ['Segoe UI', 'sans-serif'],
  scaffoldBackgroundColor: EditorColors.shell,
  colorScheme: const ColorScheme.light(
    primary: EditorColors.focus,
    onPrimary: Colors.white,
    secondary: EditorColors.secondary,
    surface: EditorColors.surface,
    onSurface: EditorColors.text,
    outline: EditorColors.border,
    surfaceTint: Colors.transparent,
  ),
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.all(Colors.white),
    trackColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? EditorColors.focus
          : EditorColors.border,
    ),
    trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: EditorColors.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: const Color(0x20202c50),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: EditorColors.border),
    ),
  ),
  dividerColor: EditorColors.border,
  dividerTheme: const DividerThemeData(
    color: EditorColors.border,
    thickness: 1,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(
      fontSize: 14,
      height: 1.4,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      color: EditorColors.muted,
      height: 1.4,
      leadingDistribution: TextLeadingDistribution.even,
    ),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    labelLarge: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 1.2,
      leadingDistribution: TextLeadingDistribution.even,
    ),
  ),
  tooltipTheme: TooltipThemeData(
    decoration: BoxDecoration(
      color: EditorColors.text,
      borderRadius: BorderRadius.circular(6),
    ),
    waitDuration: const Duration(milliseconds: 450),
  ),
  iconTheme: const IconThemeData(size: 18, color: EditorColors.secondary),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      minimumSize: const Size(36, 36),
      padding: const EdgeInsets.all(8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      hoverColor: EditorColors.hover,
      focusColor: EditorColors.selection,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      elevation: 0,
      backgroundColor: EditorColors.text,
      foregroundColor: Colors.white,
      alignment: Alignment.center,
      minimumSize: const Size(40, 36),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(40, 36),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      foregroundColor: EditorColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(36, 36),
      foregroundColor: EditorColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: EditorColors.subtle,
    contentPadding: const EdgeInsets.all(12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(11),
      borderSide: const BorderSide(color: EditorColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(11),
      borderSide: const BorderSide(color: EditorColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(11),
      borderSide: const BorderSide(color: EditorColors.focus, width: 1.5),
    ),
  ),
);

/// Pointer feedback wraps native buttons so keyboard, focus and semantics stay intact.
class MotionFeedback extends StatefulWidget {
  const MotionFeedback({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;
  @override
  State<MotionFeedback> createState() => _MotionFeedbackState();
}

class _MotionFeedbackState extends State<MotionFeedback> {
  bool hovered = false, pressed = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => hovered = true),
    onExit: (_) => setState(() {
      hovered = false;
      pressed = false;
    }),
    child: Listener(
      onPointerDown: (_) => setState(() => pressed = true),
      onPointerUp: (_) => setState(() => pressed = false),
      onPointerCancel: (_) => setState(() => pressed = false),
      child: AnimatedScale(
        duration: motionDuration(context, 120),
        curve: Curves.easeOutCubic,
        scale: !widget.enabled || MediaQuery.disableAnimationsOf(context)
            ? 1
            : pressed
            ? 0.96
            : hovered
            ? 1.025
            : 1,
        child: widget.child,
      ),
    ),
  );
}

class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  @override
  Widget build(BuildContext context) => MotionFeedback(
    enabled: onPressed != null,
    child: AnimatedContainer(
      duration: motionDuration(context),
      decoration: BoxDecoration(
        color: selected ? EditorColors.hover : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
      ),
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        isSelected: selected,
        icon: Icon(icon, size: 18),
        selectedIcon: Icon(icon, size: 18, color: EditorColors.text),
      ),
    ),
  );
}

/// A library entry action keeps the same command and keyboard semantics as its toolbar counterpart.
class LibraryAction extends StatelessWidget {
  const LibraryAction({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.primary = false,
    this.accent = EditorColors.focus,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final Color accent;
  @override
  Widget build(BuildContext context) => MotionFeedback(
    enabled: onPressed != null,
    child: Material(
      color: primary ? EditorColors.text : EditorColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: EditorColors.border),
      ),
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: primary
                        ? Colors.white
                        : accent.withValues(alpha: .08),
                  ),
                  child: Icon(
                    icon,
                    size: 24,
                    color: onPressed == null
                        ? EditorColors.muted
                        : primary
                        ? EditorColors.text
                        : accent,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: onPressed == null
                          ? EditorColors.muted
                          : primary
                          ? Colors.white
                          : EditorColors.text,
                    ),
                  ),
                ),
                if (primary)
                  const Icon(
                    Icons.chevron_right,
                    size: 22,
                    color: Colors.white,
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
