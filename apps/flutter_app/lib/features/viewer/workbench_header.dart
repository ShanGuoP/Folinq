import 'package:flutter/material.dart';
import '../../shared/editor_theme.dart';
import '../documents/document_controller.dart';

class WorkbenchHeader extends StatelessWidget {
  const WorkbenchHeader({
    super.key,
    required this.state,
    required this.showingHome,
    required this.onNavigate,
    required this.onOpen,
    required this.onSave,
    required this.onSaveAs,
    required this.onHistory,
  });
  final DocumentState state;
  final bool showingHome;
  final VoidCallback onNavigate, onOpen, onSave, onSaveAs, onHistory;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final split =
          constraints.maxWidth < 960 ||
          MediaQuery.textScalerOf(context).scale(13) > 17;
      final compact = constraints.maxWidth < 600;
      final document = showingHome ? null : state.document;
      final actions = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          TextButton.icon(
            onPressed: state.busy ? null : onOpen,
            icon: const Icon(Icons.folder_open_outlined, size: 17),
            label: const Text('打开 PDF'),
          ),
          if (document != null)
            IconButton(
              tooltip: '历史版本',
              onPressed: state.busy ? null : onHistory,
              icon: const Icon(Icons.history, size: 20),
            ),
          TextButton.icon(
            onPressed: document == null || state.busy ? null : onSave,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('保存'),
          ),
          FilledButton.icon(
            onPressed: document == null || state.busy ? null : onSaveAs,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('另存为'),
          ),
        ],
      );
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 20,
          vertical: 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                children: [
                  if (state.document != null) ...[
                    Tooltip(
                      message: showingHome ? '返回编辑' : '项目 / 历史',
                      child: TextButton.icon(
                        key: const ValueKey('workspace-back'),
                        onPressed: state.busy ? null : onNavigate,
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: Text(showingHome ? '返回编辑' : '返回项目'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  const Icon(
                    Icons.picture_as_pdf_outlined,
                    size: 22,
                    color: EditorColors.text,
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 8),
                    const Text(
                      'Folinq 页翎',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 20),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      document?.name ?? '项目与 PDF',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: EditorColors.secondary,
                      ),
                    ),
                  ),
                  if (document?.dirty == true)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Tooltip(
                        message: '尚未保存',
                        child: Icon(
                          Icons.circle,
                          size: 6,
                          color: EditorColors.warning,
                        ),
                      ),
                    ),
                  if (!split) ...[const SizedBox(width: 16), actions],
                ],
              ),
            ),
            if (split) ...[
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerRight, child: actions),
            ],
          ],
        ),
      );
    },
  );
}
