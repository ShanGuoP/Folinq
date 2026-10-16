import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/online_ocr.dart';

class OnlineOcrOptions extends ConsumerWidget {
  const OnlineOcrOptions({
    super.key,
    required this.enabled,
    required this.running,
    required this.onChanged,
  });
  final bool enabled, running;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(onlineOcrConfigProvider);
    void update(OnlineOcrConfig value) =>
        ref.read(onlineOcrConfigProvider.notifier).update(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('在线 OCR · PaddleOCR'),
          subtitle: const Text('识别扫描页，生成可编辑的文字'),
          value: enabled,
          onChanged: running ? null : onChanged,
        ),
        if (enabled) ...[
          const Text(
            '点击导出即同意将所选页面上传到下方服务，可能消耗服务额度。服务地址和 Token 仅保存在本次运行内。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: config.endpoint,
            enabled: !running,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '文档解析接口完整地址',
              hintText: 'https://服务地址/layout-parsing',
            ),
            onChanged: (v) => update(config.copyWith(endpoint: v)),
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: config.token,
            enabled: !running,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Token（无鉴权服务可留空）'),
            onChanged: (v) => update(config.copyWith(token: v)),
          ),
          DropdownButtonFormField<String>(
            initialValue: config.scheme,
            decoration: const InputDecoration(labelText: '鉴权方式'),
            items: const [
              DropdownMenuItem(
                value: 'token',
                child: Text('Authorization: token'),
              ),
              DropdownMenuItem(
                value: 'Bearer',
                child: Text('Authorization: Bearer'),
              ),
            ],
            onChanged: running
                ? null
                : (v) => update(config.copyWith(scheme: v)),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许可信内网 HTTP'),
            subtitle: const Text('HTTP 会明文传输页面和 Token，公网请使用 HTTPS。'),
            value: config.allowHttp,
            onChanged: running
                ? null
                : (v) => update(config.copyWith(allowHttp: v)),
          ),
          const Text(
            '支持 PP-StructureV3 / PaddleOCR-VL 同步文档解析接口。Markdown 含配图，保存为 ZIP；Word / TXT 仅导出识别文字，不保留配图、原生表格和原始版式。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
  }
}
