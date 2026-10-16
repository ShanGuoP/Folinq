import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/online_ocr.dart';
import '../../shared/editor_theme.dart';

class OnlineOcrOptions extends ConsumerStatefulWidget {
  const OnlineOcrOptions({
    super.key,
    required this.enabled,
    required this.running,
    required this.onChanged,
  });
  final bool enabled, running;
  final ValueChanged<bool> onChanged;
  @override
  ConsumerState<OnlineOcrOptions> createState() => _OnlineOcrOptionsState();
}

class _OnlineOcrOptionsState extends ConsumerState<OnlineOcrOptions> {
  late final TextEditingController endpoint, token;
  bool revealToken = false;
  @override
  void initState() {
    super.initState();
    final config = ref.read(onlineOcrConfigProvider);
    endpoint = TextEditingController(text: config.endpoint);
    token = TextEditingController(text: config.token);
  }

  @override
  void dispose() {
    endpoint.dispose();
    token.dispose();
    super.dispose();
  }

  void update(OnlineOcrConfig Function(OnlineOcrConfig) change) {
    ref
        .read(onlineOcrConfigProvider.notifier)
        .update(change(ref.read(onlineOcrConfigProvider)));
  }

  Widget label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );
  InputDecoration decoration(String hint, {Widget? suffix}) => InputDecoration(
    hintText: hint,
    suffixIcon: suffix,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    hintStyle: const TextStyle(fontSize: 12, color: EditorColors.muted),
    floatingLabelBehavior: FloatingLabelBehavior.never,
  );

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(onlineOcrConfigProvider);
    final jobs = config.usesJobs;
    final enabled = !widget.running;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: EditorColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: EditorColors.border),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                '在线 OCR',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              subtitle: const Text(
                '使用 PaddleOCR 识别扫描页',
                style: TextStyle(fontSize: 12, color: EditorColors.muted),
              ),
              value: widget.enabled,
              onChanged: enabled ? widget.onChanged : null,
            ),
            if (widget.enabled) ...[
              const SizedBox(height: 16),
              label('服务类型'),
              DropdownButtonFormField<OnlineOcrProtocol>(
                key: ValueKey(config.protocol),
                initialValue: config.protocol,
                isExpanded: true,
                decoration: decoration('选择服务'),
                items: const [
                  DropdownMenuItem(
                    value: OnlineOcrProtocol.auto,
                    child: Text('根据地址自动识别'),
                  ),
                  DropdownMenuItem(
                    value: OnlineOcrProtocol.jobs,
                    child: Text('AI Studio 官方云端'),
                  ),
                  DropdownMenuItem(
                    value: OnlineOcrProtocol.layout,
                    child: Text('自部署 · 同步文档解析'),
                  ),
                ],
                onChanged: enabled
                    ? (v) => update((c) => c.copyWith(protocol: v))
                    : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '接口地址',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: enabled
                        ? () {
                            endpoint.text = OnlineOcrConfig.officialEndpoint;
                            update(
                              (c) => c.copyWith(
                                endpoint: endpoint.text,
                                protocol: OnlineOcrProtocol.auto,
                              ),
                            );
                          }
                        : null,
                    child: const Text('填入官方地址', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextFormField(
                key: const ValueKey('ocr-endpoint'),
                controller: endpoint,
                enabled: enabled,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                style: const TextStyle(fontSize: 13, height: 1.4),
                decoration: decoration(
                  'https://…/api/v2/ocr/jobs 或 /layout-parsing',
                ),
                onChanged: (v) => update((c) => c.copyWith(endpoint: v)),
              ),
              const SizedBox(height: 8),
              Text(
                jobs ? '已识别：官方异步任务接口 · 自动使用 Bearer' : '同步接口会直接返回 Markdown 与配图。',
                style: const TextStyle(fontSize: 12, color: EditorColors.muted),
              ),
              const SizedBox(height: 18),
              label('访问令牌 Token'),
              TextFormField(
                key: const ValueKey('ocr-token'),
                controller: token,
                enabled: enabled,
                obscureText: !revealToken,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 13, height: 1.4),
                decoration: decoration(
                  jobs ? '填写 AI Studio 访问令牌' : '无鉴权的自部署服务可留空',
                  suffix: IconButton(
                    tooltip: revealToken ? '隐藏令牌' : '显示令牌',
                    onPressed: enabled
                        ? () => setState(() => revealToken = !revealToken)
                        : null,
                    icon: Icon(
                      revealToken
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                    ),
                  ),
                ),
                onChanged: (v) => update((c) => c.copyWith(token: v)),
              ),
              if (jobs) ...[
                const SizedBox(height: 18),
                label('文档解析模型'),
                TextFormField(
                  key: const ValueKey('ocr-model'),
                  initialValue: config.model,
                  enabled: enabled,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                  decoration: decoration('填写服务支持的模型名称'),
                  onChanged: (v) => update((c) => c.copyWith(model: v)),
                ),
                const SizedBox(height: 8),
                const Text(
                  '提交后自动等待识别结果。取消只停止等待，云端任务可能继续处理。',
                  style: TextStyle(fontSize: 12, color: EditorColors.muted),
                ),
              ] else ...[
                const SizedBox(height: 12),
                ExpansionTile(
                  key: const ValueKey('ocr-advanced'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  initiallyExpanded:
                      config.allowHttp || config.endpoint.startsWith('http://'),
                  title: const Text('高级连接设置', style: TextStyle(fontSize: 13)),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: label('鉴权方式'),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: config.scheme,
                      isExpanded: true,
                      decoration: decoration('服务要求的鉴权方式'),
                      items: const [
                        DropdownMenuItem(value: 'token', child: Text('token')),
                        DropdownMenuItem(
                          value: 'Bearer',
                          child: Text('Bearer'),
                        ),
                      ],
                      onChanged: enabled
                          ? (v) => update((c) => c.copyWith(scheme: v))
                          : null,
                    ),
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        '允许可信内网 HTTP',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        '会明文传输页面和令牌，公网请使用 HTTPS。',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: config.allowHttp,
                      onChanged: enabled
                          ? (v) => update((c) => c.copyWith(allowHttp: v))
                          : null,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: EditorColors.subtle,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '点击导出即同意将所选页面上传至所填服务，可能消耗额度。Token 仅在本次运行中保存。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: EditorColors.secondary,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Word：保留标题、粗体、列表、可编辑表格和配图；Markdown：文字与配图 ZIP；TXT：纯文字。均不保证还原原始版式。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: EditorColors.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
