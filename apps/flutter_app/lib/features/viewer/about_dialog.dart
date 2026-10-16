import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../shared/app_brand.dart';
import '../../shared/editor_theme.dart';

Future<void> showFolinqAbout(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => const FolinqAboutDialog(),
);

class FolinqAboutDialog extends StatefulWidget {
  const FolinqAboutDialog({super.key});

  @override
  State<FolinqAboutDialog> createState() => _FolinqAboutDialogState();
}

class _FolinqAboutDialogState extends State<FolinqAboutDialog> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  String? _message;
  bool _opening = false;

  Future<void> _openProject() async {
    setState(() {
      _opening = true;
      _message = null;
    });
    var opened = false;
    try {
      opened = await launchUrl(
        AppBrand.projectUrl,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Keep the address visible and copyable when no browser is available.
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      if (!opened) _message = '无法打开浏览器，请复制地址后手动访问。';
    });
  }

  Future<void> _copyProject() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: AppBrand.projectUrl.toString()),
      );
      if (mounted) setState(() => _message = '开源地址已复制');
    } catch (_) {
      if (mounted) setState(() => _message = '复制失败，可以选中下方地址手动复制。');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 460),
    scrollable: true,
    title: Row(
      children: [
        const AppIcon(size: 72),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(AppBrand.name),
              const SizedBox(height: 4),
              FutureBuilder<PackageInfo>(
                future: _packageInfo,
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  final version = info == null || info.version.isEmpty
                      ? snapshot.connectionState == ConnectionState.done
                            ? '版本信息暂不可用'
                            : '正在读取版本…'
                      : '版本 ${info.version}${info.buildNumber.isEmpty ? '' : '（构建 ${info.buildNumber}）'}';
                  return Text(
                    version,
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ),
    content: SizedBox(
      width: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('开源项目', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SelectableText(
              AppBrand.projectUrl.toString(),
              onTap: _opening ? null : _openProject,
              style: const TextStyle(
                fontSize: 13,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: _opening ? null : _openProject,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('访问 GitHub'),
              ),
              TextButton.icon(
                onPressed: _copyProject,
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('复制地址'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Apache License 2.0',
            style: TextStyle(fontSize: 12, color: EditorColors.secondary),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
