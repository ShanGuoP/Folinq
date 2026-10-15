# Folinq 页翎

一个在本地运行的 PDF 编辑器。目前先把 Windows 版做好。

改几行字、补一张图片、调整几页顺序——这些小事，最好打开文件就能做。页翎想把这条路径做得顺手一点：文档放在自己电脑上，修改后按一下 `Ctrl+S`，继续做手头的事。

项目还在持续开发，已经可以完成一批日常操作。遇到复杂排版时，也有暂时做不到的地方，下面会直接说明。

## 现在能做什么

- **读和整理文档**：多页连续滚动、缩略图跳转、搜索、复制，以及多文档切换。
- **修改内容**：编辑可识别的原生文字，添加文字和图片，拖动位置、调整大小，替换或删除对象。
- **处理页面**：插入、删除、旋转、调整顺序、合并，以及按页码范围拆分导出。
- **做标记**：高亮、下划线、注释、自由绘画和图形手签。
- **管理文件**：独立 PDF 和项目共用封面网格；项目里可以归组多份文档，历史版本在编辑页右上角查看和恢复。
- **识别扫描件**：使用 Windows 本机 OCR，复制识别结果，或添加可搜索的文字层。
- **转换与导出**：导出 PDF、PNG、JPG、TXT、Markdown 和 DOCX；也能把图片、TXT、基础 Markdown 和 DOCX 转成 PDF。
- **导出脱敏副本**：框选需要遮住的区域，生成重新栅格化的 PDF 副本。

PDF 处理和 OCR 在本机完成，不需要上传文档。OCR 使用系统已安装的识别语言。

## 保存和历史

| 操作 | 快捷键 / 入口 |
| --- | --- |
| 打开 PDF | `Ctrl+O` |
| 保存到源文件 | `Ctrl+S` |
| 另存为新文件 | `Ctrl+Shift+S` |
| 查看、恢复旧版本 | 编辑页右上角「历史版本」 |

保存会先提交尚未应用的文字修改。如果源文件已经被其他程序改过，会提示冲突，避免直接覆盖。

恢复历史版本后，可以继续编辑，也可以撤销；需要写回原文件时，再按 `Ctrl+S`。导出完成后会显示「导出成功」和保存位置。

## 关于 Word 和 Markdown 导出

这里有两个选择，适合不同用途：

- **保留原版式**：默认选项。把每页渲染成高清图片，保留文字、图片、表格和批注的外观。DOCX 按页嵌图；Markdown 会生成配套图片文件夹，移动或发送文件时请一起带上。
- **提取可编辑文字**：便于继续写作和整理文本，但不保留原来的图片、表格结构和复杂排版。

“保留原版式”导出的 Word 里，页内文字和表格不能单独编辑。完整的可编辑版式转换还没有实现。

## 还在补的部分

PDF 的情况比看上去复杂：扫描件、嵌套对象、特殊字体和多栏排版，并不都能用同一种方法修改。

目前文字编辑主要面向顶层原生文字对象。扫描件上的文字属于图片，OCR 可以帮助搜索和复制，暂时不能直接改掉图片里的字；嵌套 Form 文字和加密 PDF 也还不支持原位编辑。

交互表单、数字证书签名、完整结构化转换和大文件性能还需要继续完善。图形手签只是页面图形。脱敏副本会将整份文档转为图片页面，不保留原来的可选文字、表单或附件。

当前公开仓库专注 Windows；Android 暂不推进。

## 本地开发

界面使用 Flutter，PDF 处理和工作会话由 Rust 负责，通过 flutter_rust_bridge 连接。PDF 渲染使用 PDFium。

需要准备：

- Windows x64，以及 Visual Studio 的「使用 C++ 的桌面开发」工具链。
- Flutter 和 Rust。当前开发环境验证过 Flutter 3.47.7 / Dart 3.13.5、Rust 1.99.0。
- `flutter_rust_bridge_codegen` 2.11.1，与仓库锁定版本一致。

```powershell
cargo install flutter_rust_bridge_codegen --version 2.11.1 --locked
powershell -ExecutionPolicy Bypass -File tools/build-windows.ps1
```

构建脚本会准备固定版本的 PDFium，并优先使用 `.tools/flutter` 下的 Flutter；也可以使用系统 PATH 中的 Flutter。

**仓库只保留 Windows 源码、必要的构建配置和构建脚本。** 测试目录、其他平台工程、字体、图标、测试 PDF、视觉基线和编译产物没有上传。从干净仓库构建前，还需要补齐：

- `apps/flutter_app/assets/fonts/` 下的 `NotoSansSC.ttf`、`OFL-NotoSansSC.txt` 和 `manifest.json`，其中字体为项目使用的静态中文字体。
- `apps/flutter_app/windows/runner/resources/app_icon.ico`。

现有脚本不会自动补齐这两部分资源。

构建结果位于：

```text
apps/flutter_app/build/windows/x64/runner/Release/Folinq.exe
```

运行时请保留整个 `Release` 目录，旁边的 DLL 和 `data` 文件夹也需要一起带上。

### 检查代码

```powershell
cargo build --manifest-path rust/Cargo.toml --workspace --locked
cargo clippy --manifest-path rust/Cargo.toml --workspace --all-targets --locked -- -D warnings

cd apps/flutter_app
flutter analyze
```

修改桥接接口后，在仓库根目录重新运行 `flutter_rust_bridge_codegen generate`。

### 目录

```text
apps/flutter_app/       界面、交互和 Windows 宿主
rust/crates/
  document-core/       文档与对象的数据结构
  pdf-engine/          PDF 渲染、编辑和转换
  app-api/             工作会话、历史、保存及桥接接口
  ocr-engine/          本机文字识别
  storage/             文档索引和项目归组
tools/                 构建与环境准备脚本
```

## 反馈

如果遇到问题，欢迎在 [Issues](https://github.com/ShanGuoP/Folinq/issues) 留下操作步骤、报错和 Windows 版本。能附上一份不含隐私的最小 PDF 样本，会更容易定位。

也欢迎提交改进。涉及交互或版式的修改，附上前后截图会很有帮助。

## 开源协议与致谢

Folinq 页翎的项目代码采用 [Apache License 2.0](LICENSE)。

感谢 Flutter、Riverpod、flutter_rust_bridge、PDFium、pdfium-render、docx-rs，以及其他开源依赖。中文字体使用 Noto Sans SC，遵循 SIL Open Font License；PDFium 和其他第三方组件继续遵循各自的许可证。发布二进制时，需要一并保留相关授权和声明。
