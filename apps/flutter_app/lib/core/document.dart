class TextObject {
  TextObject(Map<String, dynamic> json, {this.kind = 'text'})
    : id = json['id'] as String,
      text = json['text'] as String? ?? '图片',
      objectIndex = json['object_index'] as int,
      editable = kind == 'text' && (json['editable'] as bool? ?? true),
      left = ((json['display_bounds'] ?? json['bounds'])['left'] as num)
          .toDouble(),
      bottom = ((json['display_bounds'] ?? json['bounds'])['bottom'] as num)
          .toDouble(),
      right = ((json['display_bounds'] ?? json['bounds'])['right'] as num)
          .toDouble(),
      top = ((json['display_bounds'] ?? json['bounds'])['top'] as num)
          .toDouble();
  final String id, text;
  final String kind;
  final int objectIndex;
  final bool editable;
  final double left, bottom, right, top;
}

class PageInfo {
  PageInfo(Map<String, dynamic> json)
    : id = json['id'] as String,
      width = (json['width'] as num).toDouble(),
      height = (json['height'] as num).toDouble(),
      objects = [
        for (final item in json['image_objects'] as List? ?? [])
          TextObject(item as Map<String, dynamic>, kind: 'image'),
        for (final item in json['text_objects'] as List)
          TextObject(item as Map<String, dynamic>),
      ],
      textContent = json['text_content'] as String? ?? '';
  final String id;
  final double width, height;
  final List<TextObject> objects;
  final String textContent;
}

class DocumentInfo {
  DocumentInfo(Map<String, dynamic> json)
    : id = json['id'] as String,
      source = json['source_path'] as String,
      version = json['version'] as int,
      dirty = json['dirty'] as bool,
      canUndo = json['can_undo'] as bool,
      canRedo = json['can_redo'] as bool,
      pages = (json['pages'] as List)
          .map((item) => PageInfo(item as Map<String, dynamic>))
          .toList();
  final String id, source;
  final int version;
  final bool dirty, canUndo, canRedo;
  final List<PageInfo> pages;
  String get name => source.replaceAll('\\', '/').split('/').last;
}
