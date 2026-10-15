import 'dart:convert';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_directories.dart';
import '../../core/document.dart';
import '../../core/rust/api.dart' as rust;
import '../../core/platform_documents.dart';
import '../../core/font_assets.dart';

final openDocumentsProvider =
    NotifierProvider<OpenDocuments, List<DocumentInfo>>(OpenDocuments.new);

class OpenDocuments extends Notifier<List<DocumentInfo>> {
  @override
  List<DocumentInfo> build() => [];
  void put(DocumentInfo document) {
    state = state.any((d) => d.id == document.id)
        ? [
            for (final item in state)
              if (item.id == document.id) document else item,
          ]
        : [...state, document];
  }

  void remove(String id) {
    state = state.where((d) => d.id != id).toList();
  }
}

class DocumentState {
  const DocumentState({
    this.document,
    this.busy = false,
    this.error,
    this.page = 0,
    this.preview,
    this.selected,
    this.ocrRunning = false,
  });
  final DocumentInfo? document;
  final bool busy;
  final String? error, preview;
  final int page;
  final TextObject? selected;
  final bool ocrRunning;
}

final documentProvider = NotifierProvider<DocumentController, DocumentState>(
  DocumentController.new,
);

class DocumentController extends Notifier<DocumentState> {
  final Map<String, DocumentState> _views = {};
  final Map<String, String> _drafts = {};
  final Map<String, Map<String, dynamic>> _editOptions = {};
  Timer? _viewTimer;
  bool _viewDisposalRegistered = false;
  void scheduleViewSave() {
    if (!_viewDisposalRegistered) {
      ref.onDispose(() => _viewTimer?.cancel());
      _viewDisposalRegistered = true;
    }
    _viewTimer?.cancel();
    _viewTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(persistView()),
    );
  }

  String _draftKey(String object) => '${state.document?.id}:$object';
  String? draftFor(String object) => _drafts[_draftKey(object)];
  Map<String, dynamic>? editOptionsFor(String object) =>
      _editOptions[_draftKey(object)];
  bool hasDrafts(String documentId) =>
      _drafts.keys.any((key) => key.startsWith('$documentId:')) ||
      _editOptions.entries.any(
        (e) => e.key.startsWith('$documentId:') && e.value['font_path'] != null,
      );
  void setDraft(String object, String value) {
    if (state.selected?.id == object && !state.busy) {
      if (value == state.selected!.text) {
        _drafts.remove(_draftKey(object));
      } else {
        _drafts[_draftKey(object)] = value;
      }
      scheduleViewSave();
    }
  }

  void setEditOptions(String object, Map<String, dynamic> options) {
    if (state.selected?.id == object && !state.busy) {
      _editOptions[_draftKey(object)] = options;
      scheduleViewSave();
    }
  }

  bool get hasActiveDraft {
    final selected = state.selected;
    return selected != null &&
        selected.editable &&
        ((draftFor(selected.id) != null &&
                draftFor(selected.id) != selected.text) ||
            _editOptions[_draftKey(selected.id)]?['font_path'] != null);
  }

  Future<bool> applyActiveDraft() async {
    final selected = state.selected;
    if (!hasActiveDraft || selected == null) return true;
    await command(
      'replace_text_options',
      value: jsonEncode({
        'text': draftFor(selected.id) ?? selected.text,
        'options': _editOptions[_draftKey(selected.id)] ?? {},
      }),
    );
    return state.error == null;
  }

  Future<bool> applyPendingDrafts() async {
    final document = state.document;
    if (document == null || state.busy) return false;
    final originalPage = document.pages[state.page].id;
    final originalSelection = state.selected?.id;
    for (final page in document.pages) {
      for (final object in page.objects.where((o) => o.editable)) {
        final key = '${document.id}:${object.id}';
        if (!_drafts.containsKey(key) &&
            _editOptions[key]?['font_path'] == null) {
          continue;
        }
        final index = state.document!.pages.indexWhere((p) => p.id == page.id);
        await goToPage(index);
        if (state.error != null) return false;
        final current = state.document!.pages[index].objects
            .where((o) => o.id == object.id)
            .firstOrNull;
        if (current == null) continue;
        select(current);
        if (!await applyActiveDraft()) return false;
      }
    }
    final index = state.document!.pages.indexWhere((p) => p.id == originalPage);
    if (index >= 0) {
      await goToPage(index);
      final selected = state.document!.pages[index].objects
          .where((o) => o.id == originalSelection)
          .firstOrNull;
      if (selected != null) select(selected);
    }
    return state.error == null;
  }

  Future<void> persistView() async {
    final current = state;
    final document = current.document;
    if (document == null || current.busy) return;
    final selected = current.selected;
    try {
      await rust.viewState(
        documentId: document.id,
        expectedVersion: BigInt.from(document.version),
        value: jsonEncode({
          'version': document.version,
          'page_id': document.pages[current.page].id,
          'selected_id': selected?.id,
          'draft': selected == null ? null : draftFor(selected.id),
          'options': selected == null ? null : editOptionsFor(selected.id),
          'drafts': {
            for (final e in _drafts.entries)
              if (e.key.startsWith('${document.id}:'))
                e.key.substring(document.id.length + 1): e.value,
          },
          'edit_options': {
            for (final e in _editOptions.entries)
              if (e.key.startsWith('${document.id}:'))
                e.key.substring(document.id.length + 1): e.value,
          },
        }),
      );
    } catch (_) {
      /* Document durability is independent of optional view restoration. */
    }
  }

  @override
  DocumentState build() => const DocumentState();

  Future<Map<String, dynamic>?> recognize(String language) async {
    final previous = state;
    if (previous.busy || previous.document == null) return null;
    state = DocumentState(
      document: previous.document,
      page: previous.page,
      preview: previous.preview,
      selected: previous.selected,
      busy: true,
      ocrRunning: true,
    );
    try {
      final result =
          jsonDecode(
                await rust.recognizePage(
                  documentId: previous.document!.id,
                  expectedVersion: BigInt.from(previous.document!.version),
                  pageIndex: previous.page,
                  language: language,
                ),
              )
              as Map<String, dynamic>;
      state = previous;
      return result;
    } catch (error) {
      state = DocumentState(
        document: previous.document,
        page: previous.page,
        preview: previous.preview,
        selected: previous.selected,
        error: readableError('$error'),
      );
      return null;
    }
  }

  Future<void> importDocument(List<String> sources) async {
    final previous = state;
    if (previous.busy) return;
    unawaited(persistView());
    state = DocumentState(
      document: previous.document,
      page: previous.page,
      preview: previous.preview,
      busy: true,
    );
    DocumentInfo? opened;
    try {
      final directory = await applicationSupportDirectory();
      final imageInput = ['.png', '.jpg', '.jpeg'].any(
        (suffix) =>
            sources.isNotEmpty && sources.first.toLowerCase().endsWith(suffix),
      );
      final font = imageInput || sources.isEmpty
          ? null
          : await FontAssets.chineseFont();
      final document = DocumentInfo(
        jsonDecode(
              await rust.createDocument(
                sources: sources,
                workspace: '${directory.path}/documents',
                fontPath: font,
              ),
            )
            as Map<String, dynamic>,
      );
      opened = document;
      final preview = await rust.renderPreview(
        documentId: document.id,
        expectedVersion: BigInt.zero,
        pageIndex: 0,
      );
      if (previous.document != null) _views[previous.document!.id] = previous;
      ref.read(openDocumentsProvider.notifier).put(document);
      state = DocumentState(document: document, preview: preview);
    } catch (error) {
      if (opened != null && state.document?.id != opened.id) {
        await rust.closeDocument(documentId: opened.id);
      }
      state = DocumentState(
        document: previous.document,
        page: previous.page,
        preview: previous.preview,
        error: readableError('$error'),
      );
    }
  }

  Future<void> cancelOcr() async {
    final document = state.document;
    if (state.ocrRunning && document != null) {
      await rust.cancelTask(documentId: document.id);
    }
  }

  Future<bool> exportAndroid(
    String format,
    List<int> pages, {
    bool markSaved = false,
  }) async {
    final previous = state;
    final document = previous.document;
    if (previous.busy || document == null) return false;
    state = DocumentState(
      document: document,
      page: previous.page,
      preview: previous.preview,
      selected: previous.selected,
      busy: true,
    );
    try {
      final path = await rust.prepareExternalExport(
        documentId: document.id,
        expectedVersion: BigInt.from(document.version),
        format: format,
        pages: pages,
      );
      const mimes = {
        'pdf': 'application/pdf',
        'txt': 'text/plain',
        'md': 'text/markdown',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'docx':
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      };
      final uri = await PlatformDocuments.save(
        path,
        'edited.$format',
        mimes[format] ?? 'application/octet-stream',
      );
      if (uri == null) {
        state = previous;
        return false;
      }
      if (markSaved) {
        final info = DocumentInfo(
          jsonDecode(
                await rust.documentCommand(
                  documentId: document.id,
                  expectedVersion: BigInt.from(document.version),
                  command: 'external_save_complete',
                  objectId: '',
                  value: '',
                ),
              )
              as Map<String, dynamic>,
        );
        ref.read(openDocumentsProvider.notifier).put(info);
        state = DocumentState(
          document: info,
          page: previous.page,
          preview: previous.preview,
          selected: previous.selected,
        );
      } else {
        state = previous;
      }
      return true;
    } catch (error) {
      state = DocumentState(
        document: document,
        page: previous.page,
        preview: previous.preview,
        selected: previous.selected,
        error: readableError('$error'),
      );
      return false;
    }
  }

  Future<void> open(String path) async {
    if (state.busy) return;
    final previous = state;
    unawaited(persistView());
    state = DocumentState(
      document: previous.document,
      page: previous.page,
      preview: previous.preview,
      selected: previous.selected,
      busy: true,
    );
    DocumentInfo? opened;
    try {
      final directory = await applicationSupportDirectory();
      opened = DocumentInfo(
        jsonDecode(
              await rust.openDocument(
                source: path,
                workspace: '${directory.path}/documents',
              ),
            )
            as Map<String, dynamic>,
      );
      final preview = await rust.renderPreview(
        documentId: opened.id,
        expectedVersion: BigInt.from(opened.version),
        pageIndex: 0,
      );
      if (previous.document != null) _views[previous.document!.id] = previous;
      state = DocumentState(document: opened, preview: preview);
      ref.read(openDocumentsProvider.notifier).put(opened);
    } catch (error) {
      if (opened != null && state.document?.id == opened.id) {
        state = DocumentState(
          document: opened,
          preview: state.preview,
          error: '$error',
        );
        return;
      }
      if (opened != null && state.document?.id != opened.id) {
        await rust.closeDocument(documentId: opened.id);
      }
      state = DocumentState(
        document: previous.document,
        page: previous.page,
        preview: previous.preview,
        selected: previous.selected,
        error: '$error',
      );
    }
  }

  Future<void> command(String command, {String value = ''}) async {
    final previous = state;
    final document = previous.document;
    if (document == null || previous.busy) return;
    state = DocumentState(
      document: document,
      page: previous.page,
      preview: previous.preview,
      selected: previous.selected,
      busy: true,
    );
    DocumentInfo? updated;
    try {
      updated = DocumentInfo(
        jsonDecode(
              await rust.documentCommand(
                documentId: document.id,
                expectedVersion: BigInt.from(document.version),
                command: command,
                objectId: previous.selected?.id ?? '',
                value: value,
              ),
            )
            as Map<String, dynamic>,
      );
      final pageId = document.pages[previous.page].id;
      final foundPage = updated.pages.indexWhere((page) => page.id == pageId);
      final nextPage = foundPage < 0
          ? previous.page.clamp(0, updated.pages.length - 1)
          : foundPage;
      if (updated.version != document.version) {
        final validIds = updated.pages
            .expand((page) => page.objects)
            .map((o) => '${document.id}:${o.id}')
            .toSet();
        _drafts.removeWhere(
          (key, _) =>
              key.startsWith('${document.id}:') && !validIds.contains(key),
        );
        _editOptions.removeWhere(
          (key, _) =>
              key.startsWith('${document.id}:') && !validIds.contains(key),
        );
        if (command.startsWith('replace_text')) {
          _drafts.remove('${document.id}:${previous.selected?.id}');
          _editOptions.remove('${document.id}:${previous.selected?.id}');
        }
      }
      final preview = await rust.renderPreview(
        documentId: updated.id,
        expectedVersion: BigInt.from(updated.version),
        pageIndex: nextPage,
      );
      state = DocumentState(
        document: updated,
        page: nextPage,
        preview: preview,
        selected: updated.pages[nextPage].objects
            .where((object) => object.id == previous.selected?.id)
            .firstOrNull,
      );
      ref.read(openDocumentsProvider.notifier).put(updated);
    } catch (error) {
      // A preview failure after a successful command must retain the new version.
      state = DocumentState(
        document: updated ?? document,
        page: previous.page.clamp(0, (updated ?? document).pages.length - 1),
        preview: updated == null ? previous.preview : null,
        selected: (updated ?? document)
            .pages[previous.page.clamp(
              0,
              (updated ?? document).pages.length - 1,
            )]
            .objects
            .where((object) => object.id == previous.selected?.id)
            .firstOrNull,
        error: readableError('$error'),
      );
      if (updated != null) {
        ref.read(openDocumentsProvider.notifier).put(updated);
      }
    } finally {
      unawaited(persistView());
    }
  }

  void switchDocument(String id) {
    if (state.busy || state.document?.id == id) return;
    final next = _views[id];
    if (next == null) return;
    persistView();
    if (state.document != null) _views[state.document!.id] = state;
    state = next;
  }

  Future<void> closeDocument(String id) async {
    if (state.busy) return;
    if (state.document?.id == id) await persistView();
    await rust.closeDocument(documentId: id);
    _views.remove(id);
    ref.read(openDocumentsProvider.notifier).remove(id);
    if (state.document?.id == id) {
      state = _views.values.lastOrNull ?? const DocumentState();
    }
  }

  Future<List<DocumentInfo>> recoverable() async {
    final directory = await applicationSupportDirectory();
    final result =
        jsonDecode(
              await rust.recoverableDocuments(
                workspace: '${directory.path}/documents',
              ),
            )
            as List;
    return result
        .map((item) => DocumentInfo(item as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> projects({
    String command = 'list',
    Map<String, dynamic> value = const {},
  }) async {
    final directory = await applicationSupportDirectory();
    return jsonDecode(
          await rust.projectCatalog(
            workspace: '${directory.path}/documents',
            command: command,
            value: jsonEncode(value),
          ),
        )
        as Map<String, dynamic>;
  }

  Future<void> openIntoProject(String path, String project) async {
    await open(path);
    final current = state;
    if (current.error != null || current.document == null) return;
    try {
      await projects(
        command: 'assign',
        value: {'document_id': current.document!.id, 'project_id': project},
      );
    } catch (error) {
      final latest = state;
      if (latest.document?.id != current.document?.id) return;
      state = DocumentState(
        document: latest.document,
        page: latest.page,
        preview: latest.preview,
        selected: latest.selected,
        error: 'PDF 已打开，但加入项目失败：$error',
      );
    }
  }

  Future<void> restore(String id) async {
    if (state.busy) return;
    if (ref.read(openDocumentsProvider).any((doc) => doc.id == id)) {
      switchDocument(id);
      return;
    }
    final previous = state;
    unawaited(persistView());
    state = DocumentState(
      document: previous.document,
      page: previous.page,
      preview: previous.preview,
      busy: true,
    );
    DocumentInfo? opened;
    try {
      final directory = await applicationSupportDirectory();
      final document = DocumentInfo(
        jsonDecode(
              await rust.restoreDocument(
                workspace: '${directory.path}/documents',
                documentId: id,
              ),
            )
            as Map<String, dynamic>,
      );
      opened = document;
      final view =
          jsonDecode(
                await rust.viewState(
                  documentId: document.id,
                  expectedVersion: BigInt.from(document.version),
                  value: null,
                ),
              )
              as Map<String, dynamic>;
      final foundPage = document.pages.indexWhere(
        (page) => page.id == view['page_id'],
      );
      final page = foundPage < 0 ? 0 : foundPage;
      final selected = document.pages[page].objects
          .where((o) => o.id == view['selected_id'])
          .firstOrNull;
      if (view['version'] == document.version && selected != null) {
        final key = '${document.id}:${selected.id}';
        if (view['draft'] is String) _drafts[key] = view['draft'] as String;
        if (view['options'] is Map) {
          _editOptions[key] = Map<String, dynamic>.from(view['options'] as Map);
        }
      }
      if (view['version'] == document.version) {
        final ids = document.pages
            .expand((p) => p.objects)
            .map((o) => o.id)
            .toSet();
        if (view['drafts'] is Map) {
          for (final e in (view['drafts'] as Map).entries) {
            if (ids.contains(e.key) && e.value is String) {
              _drafts['${document.id}:${e.key}'] = e.value as String;
            }
          }
        }
        if (view['edit_options'] is Map) {
          for (final e in (view['edit_options'] as Map).entries) {
            if (ids.contains(e.key) && e.value is Map) {
              _editOptions['${document.id}:${e.key}'] =
                  Map<String, dynamic>.from(e.value as Map);
            }
          }
        }
      }
      final preview = await rust.renderPreview(
        documentId: document.id,
        expectedVersion: BigInt.from(document.version),
        pageIndex: page,
      );
      if (previous.document != null) _views[previous.document!.id] = previous;
      ref.read(openDocumentsProvider.notifier).put(document);
      state = DocumentState(
        document: document,
        preview: preview,
        page: page,
        selected: selected,
      );
    } catch (error) {
      if (opened != null && state.document?.id != opened.id) {
        await rust.closeDocument(documentId: opened.id);
      }
      state = DocumentState(
        document: previous.document,
        page: previous.page,
        preview: previous.preview,
        error: readableError('$error'),
      );
    }
  }

  void select(TextObject object) {
    if (state.busy) return;
    state = DocumentState(
      document: state.document,
      page: state.page,
      preview: state.preview,
      selected: object,
    );
  }

  void selectOnPage(int page, TextObject object, String preview) {
    if (state.busy) return;
    state = DocumentState(
      document: state.document,
      page: page,
      preview: preview,
      selected: object,
    );
  }

  void visiblePage(int page, String preview) {
    if (state.busy || state.page == page) return;
    state = DocumentState(
      document: state.document,
      page: page,
      preview: preview,
    );
  }

  void clearSelection() {
    if (state.busy) return;
    state = DocumentState(
      document: state.document,
      page: state.page,
      preview: state.preview,
      error: state.error,
    );
  }

  Future<void> goToPage(int page) async {
    final document = state.document;
    if (document == null ||
        state.busy ||
        page < 0 ||
        page >= document.pages.length) {
      return;
    }
    state = DocumentState(document: document, page: page, busy: true);
    try {
      final preview = await rust.renderPreview(
        documentId: document.id,
        expectedVersion: BigInt.from(document.version),
        pageIndex: page,
      );
      state = DocumentState(document: document, page: page, preview: preview);
    } catch (error) {
      state = DocumentState(document: document, page: page, error: '$error');
    }
  }
}

String readableError(String error) {
  const messages = {
    'FONT_MISSING_GLYPH': '当前字体缺少新文字的字形，请在文字属性中选择支持这些字符的字体。',
    'SAVE_VERIFICATION_FAILED': '修改后的文字未能正确保存，已保留原版本和输入。请尝试更换字体。',
    'SOURCE_CHANGED': '源 PDF 已被其他程序修改。请先另存为新文件，避免覆盖外部修改。',
    'SOURCE_SAVE_FAILED': '无法写入源 PDF。请关闭其他程序中的同名文件，或选择另存为。',
    'VISUAL_OUTSIDE_REGION': '检测到编辑区域外的内容变化，已保留原版本。请更换字体或另选文字对象。',
    'UNEDITED_OBJECT_MOVED': '页面中其他对象发生了位置变化，已停止修改并保留原版本。',
    'LAYOUT_OVERFLOW': '新文字超出了原区域。请缩短内容，或开启“缩小字号以适应”。',
    'SIGNED_DOCUMENT': '这份 PDF 带有数字签名，当前禁止修改，以免使签名失效。',
    'DESTINATION_EXISTS_OR_UNWRITABLE': '目标文件已存在或无法写入。请换一个文件名，并确认保存位置可用。',
    'LAST_PAGE': '文档至少需要保留一页。',
    'OCR_LANGUAGE_UNAVAILABLE': '本机尚未安装对应的 Windows OCR 语言，请在系统语言设置中安装。',
    'TASK_CANCELLED': '识别已取消，文档未修改。',
    'UNSUPPORTED_TEXT': '当前原文字对象只支持单行替换。需要多行内容时，请使用“添加文字”。',
    'LAYOUT_COLLISION': '新字形与相邻对象发生重叠。请调整内容或开启缩小字号。',
  };
  for (final entry in messages.entries) {
    if (error.contains(entry.key)) return '${entry.value} (${entry.key})';
  }
  return error;
}
