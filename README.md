# Folinq 页翎

一个在本地运行的 PDF 编辑器。目前先把 Windows 版做好。

改几行字、补一张图片、调整几页顺序——这些小事，最好打开文件就能做。页翎想把这条路径做得顺手一点：文档放在自己电脑上，修改后按一下 `Ctrl+S`，继续做手头的事。

项目还在持续开发，已经可以完成一批日常操作。遇到复杂排版时，也有暂时做不到的地方，下面会直接说明。

## 现在能做什么

- **读和整理文档**：多页连续滚动、缩略图跳转、搜索、复制，以及多文档切换。
- **修改内容**：编辑可识别的原生文字，添加文字和图片，拖动位置、调整大小，替换或删除对象。
- **拖入打开**：将 PDF 拖到首页或编辑区即可打开，支持一次拖入多个文件；也可以把 PDF 拖到 `Folinq.exe` 图标上启动。
- **处理页面**：插入、删除、旋转、调整顺序、合并，以及按页码范围拆分导出。
- **做标记**：高亮、下划线、注释、自由绘画和图形手签。
- **管理文件**：独立 PDF 和项目共用封面网格；项目里可以归组多份文档，最近记录可单独移除，历史版本在编辑页右上角查看和恢复。
- **识别扫描件**：使用 Windows 本机 OCR，复制识别结果，或添加可搜索的文字层。
- **转换与导出**：导出 PDF、PNG、JPG、TXT、Markdown 和 DOCX；也能把图片、TXT、基础 Markdown 和 DOCX 转成 PDF。
- **导出脱敏副本**：框选需要遮住的区域，生成重新栅格化的 PDF 副本。

PDF 处理和 OCR 在本机完成，不需要上传文档。OCR 使用系统已安装的识别语言。

## 使用便携版

将 Windows x64 便携 ZIP **完整解压**，双击根目录的 `Folinq.exe` 启动。解压后的结构是：

```text
Folinq/
  Folinq.exe
  使用说明.txt
  runtime/           实际应用、DLL、字体、资源与许可证
```

请让 `runtime` 文件夹与启动程序保持在一起。升级时，将新包完整解压到另一个文件夹即可；本机已有的项目、草稿、编辑历史和导出目录偏好会继续保留。窗口较窄时，工具栏自动换行，可通过顶部的「返回项目」「返回编辑」切换页面。

仓库仅保留源码和构建脚本，便携包、测试样本和本地开发文档不随代码提交。

## 最近记录与项目

在 PDF 卡片的菜单中选择「删除记录（保留源文件）」，会从最近文档和项目列表中移除这份 PDF 的记录，重启后仍然生效。源 PDF、本机编辑历史和已有项目归组关系都会保留；删除后可以点击提示中的「撤销」，也可以重新打开 PDF，让记录重新出现。此操作不会清理磁盘上的工作文件。

删除项目分组则会让其中的 PDF 回到独立 PDF 列表，源文件和编辑历史同样保留。

## 保存和历史

| 操作 | 快捷键 / 入口 |
| --- | --- |
| 打开 PDF | `Ctrl+O` |
| 保存到源文件 | `Ctrl+S` |
| 另存为新文件 | `Ctrl+Shift+S` |
| 查看、恢复旧版本 | 编辑页右上角「历史版本」 |

保存会先提交尚未应用的文字修改。如果源文件已经被其他程序改过，会提示冲突，避免直接覆盖。

恢复历史版本后，可以继续编辑，也可以撤销；需要写回原文件时，再按 `Ctrl+S`。导出完成后会显示「导出成功」和保存位置。导出、另存为和脱敏副本共用上次选择的输出目录，重启后仍会记住；首次或该目录已不存在时，默认使用源 PDF 所在文件夹。同名文件自动添加「(1)」「(2)」编号，保留已有文件。

## 关于 Word 和 Markdown 导出

Word 默认使用「可编辑文字与版式」：把可识别文字转换成 Word 文字，保留字体、字号、粗斜体、颜色和页面位置；识别有边框的表格及合并单元格，保留表头底色和原有图片。文字使用定位段落，表格使用原生 Word 单元格，导出文件可以在 Word 中直接修改。

也可以选择「仅提取文字」，便于后续连续排版，不保留原来的图像和定位。扫描页面需要先完成 OCR 并加入可搜索文字层，再转为可编辑 Word；此时识别出来的文字可编辑，识别错误仍需校对。

PDF 只保存最终绘制结果，无法保证恢复原始 Word 的所有语义。复杂多栏、非规则表格、旋转文字、公式和特殊绘图仍需核对；目录目前保留文字外观，不会自动重建 Word 目录字段。修改较长文字时，可能需要调整定位段落或单元格大小。

Markdown 的「页面图片与版式」仍生成每页高清图片和配套资源文件夹；移动或发送时需要一起带上。选择「仅提取文字」则输出普通 Markdown 文字。

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

生成便携 ZIP 可运行 `python tools/package-windows.py`；已经构建好时使用 `--skip-build`。包的根目录仅保留 `Folinq.exe`、`runtime` 文件夹和使用说明。启动器静态链接自身运行库，实际应用、所需 DLL、资源和许可证集中放在 `runtime` 内；打包脚本检查启动器依赖并校验压缩包中的每个文件。

构建脚本会准备固定版本的 PDFium，并优先使用 `.tools/flutter` 下的 Flutter；也可以使用系统 PATH 中的 Flutter。

仓库保留 Windows 源码和构建脚本，本地文档、二进制和测试资源保持忽略。构建准备脚本会自动下载并校验固定版本的 PDFium、中文字体源文件、字体工具和字体许可证，生成静态中文字体、资源清单和缺失的 Windows 图标。需要 Python 3.11+，无需全局安装字体工具。字体输出固定时间戳并校验 SHA-256。

Rust 由 `rust-toolchain.toml` 固定为 1.99.0，准备脚本检查 Flutter 3.47.7。仓库配置了 Windows CI，用于从空资源目录执行准备、分析、原生测试和发布构建。手动检查可运行 `tools/check-windows.ps1 -Prepare`；本机另加 `-LocalUiTests` 可运行本地 Flutter 测试，缺失的测试 PDF 会自动生成。Flutter 测试和视觉基线保留在本机，公开仓库的原生回归测试与 CI 配置会随源码提交。

构建结果位于：

```text
apps/flutter_app/build/windows/x64/runner/Release/Folinq.exe
```

直接运行构建结果时，请保留整个 `Release` 目录及其 DLL、`data` 文件夹。便携打包脚本会将这些运行文件归入 `runtime`，并生成根目录启动程序；两种目录结构对应各自的启动入口。

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

感谢 Flutter、Riverpod、flutter_rust_bridge、desktop_drop、PDFium、pdfium-render、docx-rs，以及其他开源依赖。中文字体使用 Noto Sans SC，遵循 SIL Open Font License；PDFium 和其他第三方组件继续遵循各自的许可证。发布二进制时，需要一并保留相关授权和声明。
