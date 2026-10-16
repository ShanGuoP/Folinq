//! Shared geometric document structure for Markdown and editable, flowing DOCX.
//! Uses native PDF text and existing grid recognition; no models or network calls.
use super::*;

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Body,
    Heading(u8),
    List {
        ordered: bool,
        start: u32,
        prefix: usize,
    },
}
struct Paragraph<'a> {
    lines: Vec<Vec<&'a Glyph>>,
    kind: Kind,
}
enum Content<'a> {
    Text(Paragraph<'a>),
    Table(usize),
    Image(usize),
}
struct Block<'a> {
    bounds: [f32; 4],
    content: Content<'a>,
}

pub struct MarkdownExport {
    pub text: String,
    /// Original embedded pictures, in link order, never page screenshots.
    pub images: Vec<Vec<u8>>,
}

fn text(glyphs: &[&Glyph]) -> String {
    glyphs.iter().map(|g| g.text).collect()
}
fn trim(mut glyphs: Vec<&Glyph>) -> Vec<&Glyph> {
    let start = glyphs
        .iter()
        .position(|g| !g.text.is_whitespace())
        .unwrap_or(glyphs.len());
    glyphs.drain(..start);
    while glyphs.last().is_some_and(|g| g.text.is_whitespace()) {
        glyphs.pop();
    }
    glyphs
}
fn body_size(layouts: &[Layout]) -> f32 {
    let mut sizes: Vec<_> = layouts
        .iter()
        .flat_map(|p| &p.glyphs)
        .filter(|g| !g.text.is_whitespace())
        .map(|g| g.style.size)
        .collect();
    sizes.sort_by(f32::total_cmp);
    sizes.get(sizes.len() / 2).copied().unwrap_or(12.)
}
fn list_kind(value: &str) -> Option<Kind> {
    let chars: Vec<_> = value.chars().collect();
    let first = *chars.first()?;
    let mut prefix = if matches!(first, '•' | '▪' | '●' | '◦') {
        1
    } else if matches!(first, '-' | '*') && chars.get(1).is_some_and(|c| c.is_whitespace()) {
        2
    } else {
        0
    };
    let mut number = 0;
    let mut ordered = false;
    if prefix == 0 {
        let digits = chars.iter().take_while(|c| c.is_ascii_digit()).count();
        if digits == 0 || digits > 6 {
            return None;
        }
        let separator = *chars.get(digits)?;
        if !matches!(separator, '.' | ')' | '、') {
            return None;
        }
        if separator != '、' && !chars.get(digits + 1).is_some_and(|c| c.is_whitespace()) {
            return None;
        }
        number = chars[..digits].iter().collect::<String>().parse().ok()?;
        prefix = digits + 1;
        ordered = true;
    }
    while chars.get(prefix).is_some_and(|c| c.is_whitespace()) {
        prefix += 1;
    }
    (prefix < chars.len()).then_some(Kind::List {
        ordered,
        start: number,
        prefix,
    })
}
fn classify(line: &[&Glyph], body: f32) -> Kind {
    let value = text(line);
    if has_leader(&value) {
        return Kind::Body;
    }
    let size = line.iter().map(|g| g.style.size).fold(0., f32::max);
    if value.chars().count() <= 160 {
        if size >= body * 1.8 {
            return Kind::Heading(1);
        }
        if size >= body * 1.35 {
            return Kind::Heading(2);
        }
        if size >= body * 1.15 && line.iter().any(|g| g.style.bold) {
            return Kind::Heading(3);
        }
    }
    list_kind(&value).unwrap_or(Kind::Body)
}
fn has_leader(value: &str) -> bool {
    value.contains("....") || value.contains("……") || value.contains("····")
}
fn normalized_margin(value: &str) -> String {
    let mut out = String::new();
    let mut number = false;
    for c in value.chars().filter(|c| !c.is_whitespace()) {
        if c.is_ascii_digit() {
            if !number {
                out.push('#');
            }
            number = true;
        } else {
            number = false;
            out.extend(c.to_lowercase());
        }
    }
    out
}
fn repeated_margins(layouts: &[Layout]) -> HashSet<String> {
    let mut counts = HashMap::<String, usize>::new();
    for page in layouts {
        let mut seen = HashSet::new();
        for row in split_lines(page.glyphs.iter().collect()) {
            if is_margin(&row, page.height) {
                seen.insert(normalized_margin(&text(&row)));
            }
        }
        for key in seen {
            *counts.entry(key).or_default() += 1;
        }
    }
    counts
        .into_iter()
        .filter(|(key, count)| !key.is_empty() && *count >= 2 && *count * 3 >= layouts.len() * 2)
        .map(|(key, _)| key)
        .collect()
}

fn is_margin(line: &[&Glyph], height: f32) -> bool {
    let top = line.iter().map(|g| g.y).fold(f32::INFINITY, f32::min);
    let bottom = line.iter().map(|g| g.baseline).fold(0., f32::max);
    bottom < height * 0.08 || top > height * 0.92
}

// Detection and removal must compare the same horizontally separated pieces.
fn split_lines(glyphs: Vec<&Glyph>) -> Vec<Vec<&Glyph>> {
    let mut result = Vec::new();
    for row in lines(glyphs) {
        let mut start = 0;
        for end in 1..=row.len() {
            if end < row.len() && row[end].x - row[end - 1].right < row[end].style.size * 1.5 {
                continue;
            }
            let line = trim(row[start..end].to_vec());
            start = end;
            if !line.is_empty() {
                result.push(line);
            }
        }
    }
    result
}
fn in_grid(g: &Glyph, grid: &Grid) -> bool {
    let x = (g.x + g.right) / 2.;
    x >= grid.xs[0] - 0.5
        && x < *grid.xs.last().unwrap() - 0.5
        && g.baseline >= grid.ys[0]
        && g.y < *grid.ys.last().unwrap()
}

// XY-cut groups full-width headings/tables into bands and orders each column
// top-to-bottom. A bounded recursion handles irregular layouts conservatively.
fn reading_order<'a>(mut blocks: Vec<Block<'a>>, gap: f32, depth: usize) -> Vec<Block<'a>> {
    if blocks.len() < 2 {
        return blocks;
    }
    if depth < 32 {
        for axis in [0, 1] {
            let mut intervals: Vec<_> = blocks
                .iter()
                .map(|b| (b.bounds[axis], b.bounds[axis + 2]))
                .collect();
            intervals.sort_by(|a, b| a.0.total_cmp(&b.0));
            let mut end = intervals[0].1;
            let mut cut = None;
            let mut largest = if axis == 0 { gap * 1.5 } else { gap };
            for &(start, next) in intervals.iter().skip(1) {
                if start - end > largest {
                    largest = start - end;
                    cut = Some((end + start) / 2.);
                }
                end = end.max(next);
            }
            if let Some(cut) = cut {
                let (before, after): (Vec<_>, Vec<_>) =
                    blocks.into_iter().partition(|b| b.bounds[axis + 2] <= cut);
                let mut result = reading_order(before, gap, depth + 1);
                result.extend(reading_order(after, gap, depth + 1));
                return result;
            }
        }
    }
    blocks.sort_by(|a, b| {
        a.bounds[1]
            .total_cmp(&b.bounds[1])
            .then(a.bounds[0].total_cmp(&b.bounds[0]))
    });
    blocks
}
fn structure<'a>(
    page: &'a Layout,
    grids: &[Grid],
    body: f32,
    margins: &HashSet<String>,
) -> Vec<Block<'a>> {
    let mut blocks = Vec::new();
    let outside = page
        .glyphs
        .iter()
        .filter(|g| !grids.iter().any(|grid| in_grid(g, grid)))
        .collect();
    for line in split_lines(outside) {
        let top = line.iter().map(|g| g.y).fold(f32::INFINITY, f32::min);
        let bottom = line.iter().map(|g| g.baseline).fold(0., f32::max);
        if is_margin(&line, page.height) && margins.contains(&normalized_margin(&text(&line))) {
            continue;
        }
        blocks.push(Block {
            bounds: [line[0].x, top, line.last().unwrap().right, bottom],
            content: Content::Text(Paragraph {
                kind: classify(&line, body),
                lines: vec![line],
            }),
        });
    }
    for (index, grid) in grids.iter().enumerate() {
        blocks.push(Block {
            bounds: [
                grid.xs[0],
                grid.ys[0],
                *grid.xs.last().unwrap(),
                *grid.ys.last().unwrap(),
            ],
            content: Content::Table(index),
        });
    }
    for (index, image) in page.images.iter().enumerate() {
        blocks.push(Block {
            bounds: [
                image.x,
                image.y,
                image.x + image.width,
                image.y + image.height,
            ],
            content: Content::Image(index),
        });
    }
    let ordered = reading_order(blocks, body.max(8.), 0);
    let mut result: Vec<Block<'a>> = Vec::new();
    for block in ordered {
        if let Some(previous) = result.last_mut()
            && let (Content::Text(a), Content::Text(b)) = (&mut previous.content, &block.content)
            && a.kind == Kind::Body
            && b.kind == Kind::Body
        {
            let last = a.lines.last().unwrap();
            let next = &b.lines[0];
            let same_column = (previous.bounds[0] - block.bounds[0]).abs() <= body * 1.2;
            let gap = next[0].baseline - last[0].baseline;
            let end = last.last().unwrap().text;
            if same_column
                && gap > 0.
                && gap <= body * 1.8
                && !has_leader(&text(last))
                && !has_leader(&text(next))
                && !matches!(end, '.' | '!' | '?' | '。' | '！' | '？' | ':' | '：')
            {
                a.lines.extend(b.lines.clone());
                previous.bounds[2] = previous.bounds[2].max(block.bounds[2]);
                previous.bounds[3] = block.bounds[3];
                continue;
            }
        }
        result.push(block);
    }
    result
}
fn joiner(previous: char, next: char) -> &'static str {
    let cjk =
        |c: char| ('\u{2e80}'..='\u{9fff}').contains(&c) || ('\u{f900}'..='\u{faff}').contains(&c);
    if cjk(previous)
        || cjk(next)
        || matches!(previous, '-' | '\u{00ad}')
        || next.is_ascii_punctuation()
    {
        ""
    } else {
        " "
    }
}
fn markdown_paragraph(p: &Paragraph<'_>) -> String {
    let mut out = String::new();
    let mut previous = None;
    for (i, line) in p.lines.iter().enumerate() {
        let line = if i == 0 {
            if let Kind::List { prefix, .. } = p.kind {
                &line[prefix..]
            } else {
                line
            }
        } else {
            line
        };
        if let (Some(previous), Some(next)) = (previous, line.first()) {
            out.push_str(joiner(previous, next.text));
        }
        out.push_str(&inline_markdown(line, !matches!(p.kind, Kind::Heading(_))));
        previous = line.last().map(|g| g.text);
    }
    out
}
fn inline_markdown(glyphs: &[&Glyph], styled: bool) -> String {
    let mut out = String::new();
    let mut start = 0;
    while start < glyphs.len() {
        let mut end = start + 1;
        while end < glyphs.len()
            && (!styled
                || (glyphs[end].style.bold == glyphs[start].style.bold
                    && glyphs[end].style.italic == glyphs[start].style.italic))
        {
            end += 1;
        }
        let value = text(&glyphs[start..end]).replace('\u{00ad}', "");
        let trimmed = value.trim();
        if !styled || trimmed.is_empty() {
            out.push_str(&escape_md(&value));
        } else {
            let marker = match (glyphs[start].style.bold, glyphs[start].style.italic) {
                (true, true) => "***",
                (true, false) => "**",
                (false, true) => "*",
                _ => "",
            };
            let left = value.len() - value.trim_start().len();
            let right = value.trim_end().len();
            out.push_str(&escape_md(&value[..left]));
            out.push_str(marker);
            out.push_str(&escape_md(trimmed));
            out.push_str(marker);
            out.push_str(&escape_md(&value[right..]));
        }
        start = end;
    }
    out
}
fn escape_md(value: &str) -> String {
    let mut out = String::new();
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '\\' | '`' | '*' | '_' | '[' | ']' | '|' | '#' => {
                out.push('\\');
                out.push(c);
            }
            _ => out.push(c),
        }
    }
    out
}
fn cell_lines<'a>(page: &'a Layout, grid: &Grid, r: usize, c: usize) -> Vec<Vec<&'a Glyph>> {
    let cell = &grid.rows[r][c];
    if cell.root != (r, c) {
        return vec![];
    }
    lines(
        page.glyphs
            .iter()
            .filter(|g| {
                let x = (g.x + g.right) / 2.;
                x >= grid.xs[cell.col] - 0.5
                    && x < grid.xs[cell.col + cell.span] - 0.5
                    && g.baseline >= grid.ys[r]
                    && g.y < cell.bottom
            })
            .collect(),
    )
}
fn markdown_table(page: &Layout, grid: &Grid) -> String {
    let simple = grid.rows.iter().enumerate().all(|(r, row)| {
        row.iter().enumerate().all(|(c, cell)| {
            cell.span == 1 && cell.root == (r, c) && cell.bottom <= grid.ys[r + 1] + 1.
        })
    });
    let mut out = String::new();
    if simple {
        for (r, row) in grid.rows.iter().enumerate() {
            out.push('|');
            for (c, _) in row.iter().enumerate() {
                let value = cell_lines(page, grid, r, c)
                    .iter()
                    .map(|line| escape_md(&text(line)))
                    .collect::<Vec<_>>()
                    .join("<br>");
                out.push_str(&format!(" {value} |"));
            }
            out.push('\n');
            if r == 0 {
                out.push_str(&format!("|{}\n", " --- |".repeat(row.len())));
            }
        }
    } else {
        out.push_str("<table>\n");
        for (r, row) in grid.rows.iter().enumerate() {
            out.push_str("<tr>");
            for (c, cell) in row.iter().enumerate() {
                if cell.root != (r, c) {
                    continue;
                }
                let rowspan = grid
                    .ys
                    .iter()
                    .skip(r + 1)
                    .take_while(|&&y| y < cell.bottom - 1.)
                    .count()
                    + 1;
                let tag = if r == 0 { "th" } else { "td" };
                let value = cell_lines(page, grid, r, c)
                    .iter()
                    .map(|line| xml(&text(line)))
                    .collect::<Vec<_>>()
                    .join("<br>");
                out.push_str(&format!(
                    "<{tag} colspan=\"{}\" rowspan=\"{rowspan}\">{value}</{tag}>",
                    cell.span
                ));
            }
            out.push_str("</tr>\n");
        }
        out.push_str("</table>\n");
    }
    out
}

pub fn markdown(
    bytes: &[u8],
    selected: &[u16],
    resources: &str,
    remove_margins: bool,
) -> Result<MarkdownExport> {
    ensure!(!selected.is_empty() && selected.len() <= 1000, "PAGE_LIMIT");
    ensure!(
        !resources.is_empty()
            && resources
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_')),
        "INVALID_RESOURCE_NAME"
    );
    let layouts = extract(bytes, selected)?;
    let body = body_size(&layouts);
    let margins = if remove_margins {
        repeated_margins(&layouts)
    } else {
        HashSet::new()
    };
    let mut result = MarkdownExport {
        text: String::new(),
        images: vec![],
    };
    for (index, page) in layouts.iter().enumerate() {
        result
            .text
            .push_str(&format!("<!-- page {} -->\n\n", selected[index] + 1));
        let grids = grids(page);
        for block in structure(page, &grids, body, &margins) {
            match block.content {
                Content::Text(p) => {
                    let prefix = match p.kind {
                        Kind::Heading(n) => format!("{} ", "#".repeat(n as usize)),
                        Kind::List {
                            ordered: true,
                            start,
                            ..
                        } => format!("{start}. "),
                        Kind::List { .. } => "- ".into(),
                        _ => String::new(),
                    };
                    result
                        .text
                        .push_str(&format!("{prefix}{}\n\n", markdown_paragraph(&p)));
                }
                Content::Table(i) => {
                    result.text.push_str(&markdown_table(page, &grids[i]));
                    result.text.push('\n');
                }
                Content::Image(i) => {
                    result.images.push(page.images[i].png.clone());
                    let number = result.images.len();
                    result.text.push_str(&format!(
                        "![图片 {number}]({resources}/image-{number:04}.png)\n\n"
                    ));
                }
            }
        }
        ensure!(result.text.len() <= 64 * 1024 * 1024, "EXPORT_SIZE_LIMIT");
    }
    Ok(result)
}

fn flow_runs(p: &Paragraph<'_>, fit_id: &mut u32) -> String {
    let mut out = String::new();
    let mut previous = None;
    for (i, line) in p.lines.iter().enumerate() {
        let line = if i == 0 {
            if let Kind::List { prefix, .. } = p.kind {
                &line[prefix..]
            } else {
                line
            }
        } else {
            line
        };
        if let (Some(previous), Some(first)) = (previous, line.first()) {
            let space = joiner(previous, first.text);
            if !space.is_empty() {
                out.push_str("<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>");
            }
        }
        out.push_str(&styled_runs(line, 1., fit_id, false));
        previous = line.last().map(|g| g.text);
    }
    out
}

pub fn flow_docx(bytes: &[u8], selected: &[u16], remove_margins: bool) -> Result<Vec<u8>> {
    ensure!(!selected.is_empty() && selected.len() <= 1000, "PAGE_LIMIT");
    let layouts = extract(bytes, selected)?;
    let base = body_size(&layouts);
    let margins = if remove_margins {
        repeated_margins(&layouts)
    } else {
        HashSet::new()
    };
    let mut body = String::new();
    let mut media = Vec::new();
    let mut numbering = String::new();
    let mut number_instances = String::new();
    let mut list_id = 0;
    let mut active_list: Option<(bool, u32, u32)> = None;
    let mut fit_id = 0;
    for page in &layouts {
        let grids = grids(page);
        for block in structure(page, &grids, base, &margins) {
            if !matches!(&block.content,Content::Text(p) if matches!(p.kind,Kind::List {..})) {
                active_list = None;
            }
            match block.content {
                Content::Text(p) => {
                    let properties = match p.kind {
                        Kind::Heading(level) => {
                            format!("<w:pStyle w:val=\"Heading{level}\"/><w:keepNext/>")
                        }
                        Kind::List { ordered, start, .. } => {
                            let id = match active_list {
                                Some((old, number, id))
                                    if old == ordered && (!ordered || start == number + 1) =>
                                {
                                    id
                                }
                                _ => {
                                    list_id += 1;
                                    let format = if ordered { "decimal" } else { "bullet" };
                                    let label = if ordered { "%1." } else { "•" };
                                    numbering.push_str(&format!("<w:abstractNum w:abstractNumId=\"{list_id}\"><w:multiLevelType w:val=\"singleLevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"{}\"/><w:numFmt w:val=\"{format}\"/><w:lvlText w:val=\"{label}\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>",start.max(1)));
                                    number_instances.push_str(&format!("<w:num w:numId=\"{list_id}\"><w:abstractNumId w:val=\"{list_id}\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"{}\"/></w:lvlOverride></w:num>",start.max(1)));
                                    list_id
                                }
                            };
                            active_list = Some((ordered, start, id));
                            format!(
                                "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"{id}\"/></w:numPr>"
                            )
                        }
                        Kind::Body => String::new(),
                    };
                    body.push_str(&format!("<w:p><w:pPr>{properties}<w:spacing w:before=\"0\" w:after=\"120\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr>{}</w:p>",flow_runs(&p,&mut fit_id)));
                }
                Content::Table(i) => {
                    let grid = &grids[i];
                    let scale = (480. / (grid.xs.last().unwrap() - grid.xs[0])).min(1.);
                    body.push_str(&table(grid, page, scale, &mut fit_id, false));
                    body.push_str("<w:p/>");
                }
                Content::Image(i) => {
                    let picture = &page.images[i];
                    let scale = (480. / picture.width).min(1.).min(680. / picture.height);
                    let w = twip(picture.width * scale) * 635;
                    let h = twip(picture.height * scale) * 635;
                    media.push(picture.png.clone());
                    let id = media.len();
                    body.push_str(&format!("<w:p><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"{w}\" cy=\"{h}\"/><wp:docPr id=\"{id}\" name=\"PDF image {id}\"/><wp:cNvGraphicFramePr/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"{id}\" name=\"Image {id}\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId{id}\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{w}\" cy=\"{h}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"));
                }
            }
        }
        ensure!(body.len() <= 64 * 1024 * 1024, "EXPORT_SIZE_LIMIT");
    }
    body.push_str("<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\"/></w:sectPr>");
    let styles = "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"0\"/></w:pPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"1\"/></w:pPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading3\"><w:name w:val=\"heading 3\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"2\"/></w:pPr></w:style></w:styles>";
    let numbering = format!(
        "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">{numbering}{number_instances}</w:numbering>"
    );
    package_docx(&body, &media, Some(styles), Some(&numbering))
}
