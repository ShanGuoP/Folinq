import 'package:flutter/material.dart';

abstract final class EditorColors {
  static const shell = Color(0xfff1f1f4);
  static const canvas = Color(0xfffafafa);
  static const surface = Colors.white;
  static const subtle = Color(0xfff7f7f8);
  static const hover = Color(0xffe9e9ed);
  static const text = Color(0xff242428);
  static const secondary = Color(0xff53535c);
  static const muted = Color(0xff71717a);
  static const border = Color(0xffe7e7eb);
  static const focus = Color(0xff7367e8);
  static const selection = Color(0x147367e8);
  static const shadow = Color(0x0c242428);
  static const success = Color(0xff50735c);
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
  fontFamily: 'Microsoft YaHei',
  fontFamilyFallback: const ['Segoe UI', 'sans-serif'],
  scaffoldBackgroundColor: EditorColors.shell,
  colorScheme: const ColorScheme.light(
    primary: EditorColors.text,
    onPrimary: Colors.white,
    secondary: EditorColors.secondary,
    surface: EditorColors.surface,
    onSurface: EditorColors.text,
    outline: EditorColors.border,
    surfaceTint: Colors.transparent,
  ),
  dividerColor: EditorColors.border,
  dividerTheme: const DividerThemeData(
    color: EditorColors.border,
    thickness: 1,
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 13, height: 1.6),
    bodySmall: TextStyle(fontSize: 12, color: EditorColors.muted, height: 1.6),
    titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      hoverColor: EditorColors.hover,
      focusColor: EditorColors.selection,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      elevation: 0,
      minimumSize: const Size(40, 36),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      minimumSize: const Size(36, 36),
      foregroundColor: EditorColors.secondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: EditorColors.subtle,
    contentPadding: const EdgeInsets.all(12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: EditorColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: EditorColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
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
        borderRadius: BorderRadius.circular(8),
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
