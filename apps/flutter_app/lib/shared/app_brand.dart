import 'package:flutter/material.dart';

abstract final class AppBrand {
  static const name = 'Folinq PDF';
  static const icon = 'assets/branding/folinq.png';
  static final projectUrl = Uri.parse('https://github.com/ShanGuoP/Folinq');
}

class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    AppBrand.icon,
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
  );
}
