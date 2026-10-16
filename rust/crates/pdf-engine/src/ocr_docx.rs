//! Structured OCR Markdown/HTML to editable Word. Never fetch resources here.
use anyhow::{Context, Result, ensure};
use docx_rs::*;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use quick_xml::{Reader, events::Event as XmlEvent};
use std::{collections::BTreeMap, io::Cursor};

#[derive(Default, Debug)]
struct Node {
    tag: String,
    text: String,
    attrs: BTreeMap<String, String>,
    children: Vec<Node>,
}
impl Node {
    fn element(tag: &str) -> Self {
        Self {
            tag: tag.into(),
            ..Self::default()
        }
    }
    fn attr(&self, key: &str) -> &str {
        self.attrs.get(key).map(String::as_str).unwrap_or("")
    }
}
struct Tree {
    stack: Vec<Node>,
    count: usize,
}

// HTML permits literal ampersands in text and unquoted attributes. Escape only
// references that XML cannot read, while retaining recognized HTML5 entities.
fn normalize_html_entities(html: &str) -> String {
    let mut parts = html.split('&');
    let mut result = String::with_capacity(html.len());
    result.push_str(parts.next().unwrap_or(""));
    for part in parts {
        let valid = part.split_once(';').is_some_and(|(name, _)| {
            name.len() <= 64
                && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'#')
                && quick_xml::escape::unescape(&format!("&{name};")).is_ok()
        });
        result.push_str(if valid { "&" } else { "&amp;" });
        result.push_str(part);
    }
    result
}
impl Tree {
    fn new() -> Self {
        Self {
            stack: vec![Node::element("root")],
            count: 0,
        }
    }
    fn add(&mut self, node: Node) -> Result<()> {
        self.count += 1;
        ensure!(self.count <= 100_000, "OCR_STRUCTURE_LIMIT");
        self.stack.last_mut().unwrap().children.push(node);
        Ok(())
    }
    fn open(&mut self, node: Node) -> Result<()> {
        ensure!(self.stack.len() < 64, "OCR_STRUCTURE_LIMIT");
        self.stack.push(node);
        Ok(())
    }
    fn close(&mut self, tag: &str) -> Result<()> {
        if let Some(at) = self
            .stack
            .iter()
            .rposition(|n| n.tag == tag)
            .filter(|i| *i > 0)
        {
            while self.stack.len() > at {
                let node = self.stack.pop().unwrap();
                self.add(node)?;
            }
        }
        Ok(())
    }
    fn text(&mut self, text: &str) -> Result<()> {
        self.add(Node {
            text: text.into(),
            ..Node::default()
        })
    }
    fn html(&mut self, html: &str) -> Result<()> {
        // HTML fragments from OCR need not be a complete XML document.
        let normalized = normalize_html_entities(html);
        let mut reader = Reader::from_str(&normalized);
        reader.config_mut().check_end_names = false;
        // Inline HTML arrives as separate start/end events. Tree owns the
        // cross-fragment stack; this local XML reader must not reject ends.
        reader.config_mut().allow_unmatched_ends = true;
        loop {
            let event = reader.read_event().context("OCR_INVALID_HTML")?;
            match event {
                XmlEvent::Start(ref e) | XmlEvent::Empty(ref e) => {
                    let tag = String::from_utf8_lossy(e.name().as_ref()).to_lowercase();
                    let mut node = Node::element(&tag);
                    for a in e.html_attributes().with_checks(false) {
                        let a = a.context("OCR_INVALID_HTML")?;
                        node.attrs.insert(
                            String::from_utf8_lossy(a.key.as_ref()).to_lowercase(),
                            a.decoded_and_normalized_value(
                                quick_xml::XmlVersion::Implicit1_0,
                                reader.decoder(),
                            )?
                            .into_owned(),
                        );
                    }
                    if matches!(event, XmlEvent::Empty(_))
                        || matches!(
                            tag.as_str(),
                            "img" | "br" | "hr" | "wbr" | "meta" | "input" | "source" | "link"
                        )
                    {
                        self.add(node)?;
                    } else {
                        self.open(node)?;
                    }
                }
                XmlEvent::End(e) => {
                    self.close(&String::from_utf8_lossy(e.name().as_ref()).to_lowercase())?
                }
                XmlEvent::Text(e) => self.text(&quick_xml::escape::unescape(&e.decode()?)?)?,
                XmlEvent::CData(e) => self.text(&e.decode()?)?,
                XmlEvent::GeneralRef(e) => {
                    self.text(&quick_xml::escape::unescape(&format!("&{};", e.decode()?))?)?;
                }
                XmlEvent::Eof => break,
                _ => {}
            }
        }
        Ok(())
    }
}
fn tree(markdown: &str) -> Result<Node> {
    let mut t = Tree::new();
    let mut html_block = None::<String>;
    for event in Parser::new_ext(
        markdown,
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH,
    ) {
        match event {
            Event::Start(tag) => {
                let mut node = match tag {
                    Tag::Paragraph => Node::element("p"),
                    Tag::Heading { level, .. } => Node::element(&format!("h{}", level as u8)),
                    Tag::Strong => Node::element("strong"),
                    Tag::Emphasis => Node::element("em"),
                    Tag::Strikethrough => Node::element("s"),
                    Tag::List(start) => {
                        let mut node = Node::element(if start.is_some() { "ol" } else { "ul" });
                        node.attrs
                            .insert("start".into(), start.unwrap_or(1).to_string());
                        node
                    }
                    Tag::Item => Node::element("li"),
                    Tag::Table(_) => Node::element("table"),
                    Tag::TableHead => Node::element("thead-row"),
                    Tag::TableRow => Node::element("tr"),
                    Tag::TableCell => Node::element("td"),
                    Tag::Image { dest_url, .. } => {
                        let mut node = Node::element("img");
                        node.attrs.insert("src".into(), dest_url.to_string());
                        node
                    }
                    Tag::CodeBlock(_) => Node::element("pre"),
                    Tag::BlockQuote(_) => Node::element("blockquote"),
                    Tag::HtmlBlock => {
                        html_block = Some(String::new());
                        continue;
                    }
                    _ => Node::element("span"),
                };
                // Explicitly discard unsupported attributes; content remains editable.
                node.text.clear();
                t.open(node)?;
            }
            Event::End(tag) => {
                let name = match tag {
                    TagEnd::Paragraph => "p".into(),
                    TagEnd::Heading(level) => format!("h{}", level as u8),
                    TagEnd::Strong => "strong".into(),
                    TagEnd::Emphasis => "em".into(),
                    TagEnd::Strikethrough => "s".into(),
                    TagEnd::List(true) => "ol".into(),
                    TagEnd::List(false) => "ul".into(),
                    TagEnd::Item => "li".into(),
                    TagEnd::Table => "table".into(),
                    TagEnd::TableHead => "thead-row".into(),
                    TagEnd::TableRow => "tr".into(),
                    TagEnd::TableCell => "td".into(),
                    TagEnd::Image => "img".into(),
                    TagEnd::CodeBlock => "pre".into(),
                    TagEnd::BlockQuote(_) => "blockquote".into(),
                    TagEnd::HtmlBlock => {
                        if let Some(source) = html_block.take() {
                            t.html(&source)?;
                        }
                        continue;
                    }
                    _ => "span".into(),
                };
                t.close(&name)?;
            }
            Event::Text(value) | Event::InlineMath(value) | Event::DisplayMath(value) => {
                t.text(&value)?
            }
            Event::Code(value) => {
                t.open(Node::element("code"))?;
                t.text(&value)?;
                t.close("code")?;
            }
            Event::Html(value) => {
                if let Some(source) = html_block.as_mut() {
                    source.push_str(&value);
                } else {
                    t.html(&value)?;
                }
            }
            Event::InlineHtml(value) => t.html(&value)?,
            Event::SoftBreak => t.text(" ")?,
            Event::HardBreak => t.add(Node::element("br"))?,
            Event::Rule => t.add(Node::element("hr"))?,
            _ => {}
        }
    }
    while t.stack.len() > 1 {
        let node = t.stack.pop().unwrap();
        t.add(node)?;
    }
    Ok(t.stack.pop().unwrap())
}

#[derive(Clone, Copy, Default)]
struct Format {
    bold: bool,
    italic: bool,
    strike: bool,
    code: bool,
}
struct Writer<'a> {
    document: Docx,
    resources: &'a BTreeMap<String, Vec<u8>>,
    pictures: BTreeMap<String, (Vec<u8>, u32, u32)>,
    pixels: u64,
    next_number: usize,
}
impl Writer<'_> {
    fn picture(&mut self, name: &str, max_width: u32) -> Result<Pic> {
        if !self.pictures.contains_key(name) {
            let bytes = self.resources.get(name).context("OCR_MISSING_IMAGE")?;
            let mut reader = image::ImageReader::new(Cursor::new(bytes)).with_guessed_format()?;
            let mut limits = image::Limits::default();
            limits.max_image_width = Some(16_000);
            limits.max_image_height = Some(16_000);
            limits.max_alloc = Some(128 * 1024 * 1024);
            reader.limits(limits);
            let image = reader.decode().context("OCR_INVALID_IMAGE")?;
            let (w, h) = (image.width(), image.height());
            self.pixels += u64::from(w) * u64::from(h);
            ensure!(
                w > 0 && h > 0 && self.pixels <= 32_000_000,
                "OCR_IMAGE_LIMIT"
            );
            let mut png = Cursor::new(Vec::new());
            image.write_to(&mut png, image::ImageFormat::Png)?;
            self.pictures.insert(name.into(), (png.into_inner(), w, h));
        }
        let (bytes, w, h) = &self.pictures[name];
        let scale = (max_width as f64 / *w as f64)
            .min(800.0 / *h as f64)
            .min(1.0);
        Ok(Pic::new_with_dimensions(bytes.clone(), *w, *h).size(
            ((*w as f64 * scale).max(1.0) * 9525.0) as u32,
            ((*h as f64 * scale).max(1.0) * 9525.0) as u32,
        ))
    }
    fn inline(
        &mut self,
        nodes: &[Node],
        mut p: Paragraph,
        f: Format,
        width: u32,
    ) -> Result<Paragraph> {
        for n in nodes {
            if n.tag.is_empty() {
                let mut run = Run::new().add_text(&n.text);
                if f.bold {
                    run = run.bold();
                }
                if f.italic {
                    run = run.italic();
                }
                if f.strike {
                    run = run.strike();
                }
                if f.code {
                    run = run.fonts(RunFonts::new().ascii("Consolas"));
                }
                p = p.add_run(run);
            } else {
                match n.tag.as_str() {
                    "script" | "style" | "ul" | "ol" | "table" => {}
                    "img" => {
                        p = p.add_run(Run::new().add_image(self.picture(n.attr("src"), width)?));
                    }
                    "br" => {
                        p = p.add_run(Run::new().add_break(BreakType::TextWrapping));
                    }
                    _ => {
                        let mut child = f;
                        match n.tag.as_str() {
                            "strong" | "b" | "th" => child.bold = true,
                            "em" | "i" => child.italic = true,
                            "s" | "del" => child.strike = true,
                            "code" | "pre" => child.code = true,
                            _ => {}
                        }
                        p = self.inline(&n.children, p, child, width)?;
                        if matches!(n.tag.as_str(), "p" | "div") {
                            p = p.add_run(Run::new().add_break(BreakType::TextWrapping));
                        }
                    }
                }
            }
        }
        Ok(p)
    }
    fn paragraph(
        &mut self,
        nodes: &[Node],
        heading: Option<usize>,
        list: Option<(usize, usize)>,
    ) -> Result<()> {
        if nodes.is_empty() {
            return Ok(());
        }
        let mut p = Paragraph::new();
        if let Some(level) = heading {
            p = p.style(&format!("Heading{level}")).outline_lvl(level - 1);
        }
        if let Some((id, depth)) = list {
            p = p.numbering(NumberingId::new(id), IndentLevel::new(depth));
        }
        p = self.inline(nodes, p, Format::default(), 600)?;
        self.document = std::mem::take(&mut self.document).add_paragraph(p);
        Ok(())
    }
    fn blocks(
        &mut self,
        nodes: &[Node],
        mut list: Option<(usize, usize)>,
        depth: usize,
    ) -> Result<()> {
        let mut inline = Vec::new();
        // Borrowed slices preserve order around nested lists/tables.
        for (index, n) in nodes.iter().enumerate() {
            let block = matches!(
                n.tag.as_str(),
                "p" | "div" | "blockquote" | "pre" | "table" | "ul" | "ol" | "hr"
            ) || matches!(n.tag.as_str(), "h1" | "h2" | "h3" | "h4" | "h5" | "h6");
            if !block {
                inline.push(index);
                continue;
            }
            if let Some(start) = inline.first().copied() {
                self.paragraph(&nodes[start..index], None, list.take())?;
                inline.clear();
            }
            match n.tag.as_str() {
                "table" => {
                    let table = self.table(n)?;
                    self.document = std::mem::take(&mut self.document).add_table(table);
                }
                "ul" | "ol" => {
                    ensure!(depth < 9, "OCR_STRUCTURE_LIMIT");
                    self.next_number += 1;
                    let id = self.next_number;
                    let start = n
                        .attr("start")
                        .parse::<usize>()
                        .unwrap_or(1)
                        .min(i32::MAX as usize);
                    let mut abstract_num = AbstractNumbering::new(id);
                    for level in 0..9 {
                        abstract_num = abstract_num.add_level(
                            Level::new(
                                level,
                                Start::new(start),
                                NumberFormat::new(if n.tag == "ol" { "decimal" } else { "bullet" }),
                                LevelText::new(if n.tag == "ol" {
                                    format!("%{}.", level + 1)
                                } else {
                                    "•".into()
                                }),
                                LevelJc::new("left"),
                            )
                            .indent(
                                Some((level as i32 + 1) * 720),
                                Some(SpecialIndentType::Hanging(360)),
                                None,
                                None,
                            ),
                        );
                    }
                    self.document = std::mem::take(&mut self.document)
                        .add_abstract_numbering(abstract_num)
                        .add_numbering(Numbering::new(id, id));
                    for item in n.children.iter().filter(|c| c.tag == "li") {
                        self.blocks(&item.children, Some((id, depth)), depth + 1)?;
                    }
                }
                "hr" => {
                    self.paragraph(
                        &[Node {
                            text: "────────".into(),
                            ..Node::default()
                        }],
                        None,
                        None,
                    )?;
                }
                "div" | "blockquote" => self.blocks(&n.children, list.take(), depth)?,
                _ => {
                    let heading = n
                        .tag
                        .strip_prefix('h')
                        .and_then(|v| v.parse::<usize>().ok());
                    if n.tag == "pre" {
                        let p = self.inline(
                            &n.children,
                            Paragraph::new(),
                            Format {
                                code: true,
                                ..Format::default()
                            },
                            600,
                        )?;
                        self.document = std::mem::take(&mut self.document).add_paragraph(p);
                    } else {
                        self.paragraph(&n.children, heading, list.take())?;
                    }
                }
            }
        }
        if let Some(start) = inline.first().copied() {
            self.paragraph(&nodes[start..], None, list)?;
        }
        Ok(())
    }
    fn table(&mut self, node: &Node) -> Result<Table> {
        fn rows<'a>(n: &'a Node, out: &mut Vec<&'a Node>) {
            for c in &n.children {
                if matches!(c.tag.as_str(), "tr" | "thead-row") {
                    out.push(c);
                } else if matches!(c.tag.as_str(), "thead" | "tbody" | "tfoot") {
                    rows(c, out);
                }
            }
        }
        let mut source = Vec::new();
        rows(node, &mut source);
        ensure!(
            !source.is_empty() && source.len() <= 10_000,
            "OCR_INVALID_TABLE"
        );
        let mut output = Vec::new();
        let mut columns = 0;
        // Active vertical merges: start column -> (remaining rows, width).
        let mut active: BTreeMap<usize, (usize, usize)> = BTreeMap::new();
        for row in source {
            let mut cells = Vec::new();
            let mut col = 0;
            let mut input = row
                .children
                .iter()
                .filter(|n| matches!(n.tag.as_str(), "td" | "th"))
                .peekable();
            let mut next = BTreeMap::new();
            while input.peek().is_some() || active.range(col..).next().is_some() {
                ensure!(col < 128, "OCR_STRUCTURE_LIMIT");
                if let Some(&(remaining, width)) = active.get(&col) {
                    cells.push(
                        TableCell::new()
                            .grid_span(width)
                            .vertical_merge(VMergeType::Continue)
                            .add_paragraph(Paragraph::new()),
                    );
                    if remaining > 1 {
                        next.insert(col, (remaining - 1, width));
                    }
                    col += width;
                } else if let Some(cell) = input.next() {
                    let span = |key: &str| -> Result<usize> {
                        let v = if cell.attr(key).is_empty() {
                            1
                        } else {
                            cell.attr(key)
                                .parse::<usize>()
                                .context("OCR_INVALID_TABLE")?
                        };
                        ensure!(v > 0 && v <= 128, "OCR_INVALID_TABLE");
                        Ok(v)
                    };
                    let width = span("colspan")?;
                    let height = span("rowspan")?;
                    ensure!(
                        col + width <= 128 && active.range(col..col + width).next().is_none(),
                        "OCR_INVALID_TABLE"
                    );
                    let p = self.inline(
                        &cell.children,
                        Paragraph::new(),
                        Format {
                            bold: cell.tag == "th" || row.tag == "thead-row",
                            ..Format::default()
                        },
                        (600 / row.children.len().max(1) as u32).max(32),
                    )?;
                    let mut result = TableCell::new().grid_span(width).add_paragraph(p);
                    if height > 1 {
                        result = result.vertical_merge(VMergeType::Restart);
                        next.insert(col, (height - 1, width));
                    }
                    cells.push(result);
                    col += width;
                } else {
                    cells.push(TableCell::new().add_paragraph(Paragraph::new()));
                    col += 1;
                }
            }
            active = next;
            columns = columns.max(col);
            output.push(TableRow::new(cells));
        }
        ensure!(active.is_empty(), "OCR_INVALID_TABLE");
        ensure!(columns > 0, "OCR_INVALID_TABLE");
        Ok(Table::new(output).set_grid(vec![9000 / columns; columns]))
    }
}

pub fn export(markdown: &str, resources: &BTreeMap<String, Vec<u8>>) -> Result<Vec<u8>> {
    export_pages(&[(markdown.to_owned(), String::new())], resources)
}

/// Each page carries a prefix for its image resources, so identical image names
/// from different OCR pages cannot collide. Resolve parsed destinations rather
/// than replacing Markdown text (which also supports image titles and escapes).
pub fn export_pages(
    pages: &[(String, String)],
    resources: &BTreeMap<String, Vec<u8>>,
) -> Result<Vec<u8>> {
    fn rebase(node: &mut Node, prefix: &str) {
        if node.tag == "img" {
            node.attrs
                .insert("src".into(), format!("{prefix}{}", node.attr("src")));
        }
        for child in &mut node.children {
            rebase(child, prefix);
        }
    }
    let mut document = Docx::new().add_style(
        Style::new("Normal", StyleType::Paragraph)
            .name("Normal")
            .size(22),
    );
    for level in 1..=6 {
        document = document.add_style(
            Style::new(format!("Heading{level}"), StyleType::Paragraph)
                .name(format!("Heading {level}"))
                .size(40 - level * 3)
                .bold(),
        );
    }
    let mut writer = Writer {
        document,
        resources,
        pictures: BTreeMap::new(),
        pixels: 0,
        next_number: 0,
    };
    for (index, (markdown, prefix)) in pages.iter().enumerate() {
        let mut root = tree(markdown)?;
        rebase(&mut root, prefix);
        if index > 0 {
            writer.document = std::mem::take(&mut writer.document)
                .add_paragraph(Paragraph::new().add_run(Run::new().add_break(BreakType::Page)));
        }
        writer.blocks(&root.children, None, 0)?;
    }
    let mut output = Cursor::new(Vec::new());
    writer.document.build().pack(&mut output)?;
    Ok(output.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    fn xml(bytes: &[u8], name: &str) -> Result<String> {
        let mut zip = zip::ZipArchive::new(Cursor::new(bytes))?;
        let mut result = String::new();
        zip.by_name(name)?.read_to_string(&mut result)?;
        Ok(result)
    }
    fn picture(format: image::ImageFormat) -> Result<Vec<u8>> {
        let mut bytes = Cursor::new(Vec::new());
        image::DynamicImage::new_rgb8(80, 40).write_to(&mut bytes, format)?;
        Ok(bytes.into_inner())
    }
    #[test]
    fn markdown_becomes_native_headings_runs_lists_tables_and_media() -> Result<()> {
        let source = "# 文档标题\n\n正文 **加粗** 与 *斜体*。\n\n3. 第一项\n4. 第二项\n   - 子项\n\n- 无序项\n\n| 项目 | 金额 |\n| --- | --- |\n| **甲** | 123 |\n\n![配图](imgs/a.png)\n";
        let images = BTreeMap::from([("imgs/a.png".into(), picture(image::ImageFormat::Png)?)]);
        let bytes = export(source, &images)?;
        let doc = xml(&bytes, "word/document.xml")?;
        assert!(doc.contains("Heading1") && doc.contains("outlineLvl"));
        assert!(doc.contains("<w:b") && doc.contains("<w:i"));
        assert!(doc.contains("<w:numPr>") && doc.contains("<w:ilvl w:val=\"1\""));
        assert!(doc.contains("<w:tbl>") && doc.contains("金额") && doc.contains("123"));
        assert!(doc.contains("<w:drawing>"));
        let nums = xml(&bytes, "word/numbering.xml")?;
        assert!(
            nums.contains("decimal")
                && nums.contains("bullet")
                && nums.contains("<w:start w:val=\"3\"")
        );
        let zip = zip::ZipArchive::new(Cursor::new(&bytes))?;
        assert!(zip.file_names().any(|n| n.starts_with("word/media/")));
        let rels = xml(&bytes, "word/_rels/document.xml.rels")?;
        assert!(rels.contains("relationships/image"));
        if let Some(directory) = std::env::var_os("FOLINQ_OCR_SAMPLE_DIR") {
            std::fs::create_dir_all(&directory)?;
            std::fs::write(
                std::path::Path::new(&directory).join("ocr-structured.docx"),
                &bytes,
            )?;
        }
        Ok(())
    }
    #[test]
    fn html_tables_keep_spans_styles_entities_and_jpeg_images() -> Result<()> {
        let html = "<h2>HTML 标题</h2>\n<table><tbody><tr><th rowspan=\"2\">分类</th><th colspan=\"2\">数据</th></tr><tr><td><b>甲 &amp; 乙</b><br>下一行</td><td><img src=\"a.jpg\"></td></tr></tbody></table>\n<p><strong>粗体</strong><em>斜体</em>&nbsp;正文 &times; 2</p>";
        let images = BTreeMap::from([("a.jpg".into(), picture(image::ImageFormat::Jpeg)?)]);
        let bytes = export(html, &images)?;
        let doc = xml(&bytes, "word/document.xml")?;
        assert!(doc.contains("Heading2"));
        assert!(doc.contains("<w:gridSpan w:val=\"2\""));
        assert!(doc.contains("<w:vMerge w:val=\"restart\""));
        assert!(doc.contains("<w:vMerge w:val=\"continue\""));
        let mut reader = Reader::from_str(&doc);
        let mut visible = String::new();
        loop {
            match reader.read_event()? {
                XmlEvent::Text(e) => visible.push_str(&e.decode()?),
                XmlEvent::GeneralRef(e) => {
                    visible.push_str(&quick_xml::escape::unescape(&format!("&{};", e.decode()?))?)
                }
                XmlEvent::Eof => break,
                _ => {}
            }
        }
        assert!(visible.contains("甲 & 乙") && visible.contains("下一行"));
        assert!(visible.contains("× 2"));
        assert!(doc.contains("<w:drawing>") && doc.contains("粗体"));
        Ok(())
    }
    #[test]
    fn missing_or_invalid_images_stop_export_instead_of_losing_pictures() {
        assert!(
            export("![a](absent.png)", &BTreeMap::new())
                .unwrap_err()
                .to_string()
                .contains("OCR_MISSING_IMAGE")
        );
        let images = BTreeMap::from([("a.png".into(), b"invalid".to_vec())]);
        assert!(export("![a](a.png)", &images).is_err());
    }

    #[test]
    fn inline_html_fragments_keep_formatting_across_markdown_events() -> Result<()> {
        let bytes = export("正文 <b>加粗</b> 与 <i>斜体</i>，结束。", &BTreeMap::new())?;
        let doc = xml(&bytes, "word/document.xml")?;
        assert!(doc.contains("加粗") && doc.contains("斜体") && doc.contains("结束"));
        assert!(doc.contains("<w:b") && doc.contains("<w:i"));
        Ok(())
    }

    #[test]
    fn multiline_html_tables_accept_html_attributes_and_split_tags() -> Result<()> {
        let source = "前文\n\n<table\n border=1>\n<tbody>\n<tr>\n<th nowrap rowspan=2>分类</th>\n<th colspan=2>数据</th>\n</tr>\n<tr>\n<td><b>甲</b></td>\n<td>123</td>\n</tr>\n</tbody>\n</table>\n\n后文";
        let bytes = export(source, &BTreeMap::new())?;
        let doc = xml(&bytes, "word/document.xml")?;
        assert!(doc.contains("分类") && doc.contains("123") && doc.contains("后文"));
        assert!(doc.contains("<w:tbl>") && doc.contains("<w:vMerge"));
        assert!(doc.contains("<w:gridSpan w:val=\"2\""));
        Ok(())
    }

    #[test]
    fn html_text_accepts_literal_ampersands() -> Result<()> {
        let bytes = export(
            "<table><tr><td>R&D</td><td>甲 & 乙</td></tr></table>",
            &BTreeMap::new(),
        )?;
        let doc = xml(&bytes, "word/document.xml")?;
        let mut reader = Reader::from_str(&doc);
        let mut visible = String::new();
        loop {
            match reader.read_event()? {
                XmlEvent::Text(e) => visible.push_str(&e.decode()?),
                XmlEvent::GeneralRef(e) => {
                    visible.push_str(&quick_xml::escape::unescape(&format!("&{};", e.decode()?))?)
                }
                XmlEvent::Eof => break,
                _ => {}
            }
        }
        assert!(visible.contains("R&D") && visible.contains("甲 & 乙"));
        Ok(())
    }
    #[test]
    fn oversized_spans_and_deep_html_fail_without_panics() {
        assert!(
            export(
                "<table><tr><td colspan=\"1000000\">x</td></tr></table>",
                &BTreeMap::new()
            )
            .is_err()
        );
        assert!(
            export(
                &format!("{}x{}", "<div>".repeat(70), "</div>".repeat(70)),
                &BTreeMap::new()
            )
            .is_err()
        );
    }
    #[test]
    fn separate_numbered_lists_have_independent_starts_and_continuations() -> Result<()> {
        let bytes = export(
            "7. first\n\n   continuation\n\n8. second\n\nseparator\n\n2. restarted",
            &BTreeMap::new(),
        )?;
        let doc = xml(&bytes, "word/document.xml")?;
        assert_eq!(doc.matches("<w:numPr>").count(), 3);
        assert!(doc.contains("continuation") && doc.contains("restarted"));
        let nums = xml(&bytes, "word/numbering.xml")?;
        assert!(nums.contains("<w:start w:val=\"7\"") && nums.contains("<w:start w:val=\"2\""));
        Ok(())
    }
}
