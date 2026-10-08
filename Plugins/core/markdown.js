// Pix's Markdown: what answers use, rendered offline. Math ($…$, $$…$$, \(…\), \[…\]) is typeset
// with KaTeX when it's on the page. Handles headings, paragraphs, bullet and numbered lists
// (mixed in with text), tables, code blocks, quotes, dividers, bold, italic, inline code, links.
window.PixMarkdown = (() => {
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const tex = (t, display) => {
    if (!window.katex) return esc(t);
    try { return katex.renderToString(t, { displayMode: display, throwOnError: false }); } catch (e) { return esc(t); }
  };

  function inline(s) {
    return s
      .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2">$1</a>')
      .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
      .replace(/(^|[^*\w])\*(?!\s)(.+?)\*(?!\w)/g, "$1<i>$2</i>")
      .replace(/(^|[^_\w])_(?!\s)(.+?)_(?!\w)/g, "$1<i>$2</i>")
      .replace(/`([^`]+)`/g, "<code>$1</code>");
  }

  const isUL = (l) => /^\s*[-*•+] +/.test(l);
  const isOL = (l) => /^\s*\d+[.)] +/.test(l);
  const isHeading = (l) => /^#{1,6} /.test(l);
  const isRule = (l) => /^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(l);
  const isQuote = (l) => /^\s*&gt; ?/.test(l);
  const isRow = (l) => /^\s*\|.*\|\s*$/.test(l);
  const isDivider = (l) => /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(l);
  const isHold = (l) => /^\u0002\d+\u0002$/.test(l.trim());  // a code block placeholder
  const startsBlock = (l, next) => isUL(l) || isOL(l) || isHeading(l) || isRule(l) || isQuote(l) || isHold(l) || (isRow(l) && next !== undefined && isDivider(next));

  function cells(row) {
    return row.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
  }

  function list(lines, ordered) {
    const tag = ordered ? "ol" : "ul", strip = ordered ? /^\s*\d+[.)] +/ : /^\s*[-*•+] +/;
    const items = [];
    for (const l of lines) {
      if ((ordered ? isOL(l) : isUL(l)) || items.length === 0) items.push(l.replace(strip, ""));
      else items[items.length - 1] += "<br>" + l.trim();  // a wrapped or indented line belongs to the item above
    }
    const first = ordered ? parseInt(lines[0], 10) : 1;
    return `<${tag}${ordered && first > 1 ? ` start="${first}"` : ""}>` + items.map((i) => `<li>${i}</li>`).join("") + `</${tag}>`;
  }

  function blocks(s) {
    const lines = s.split("\n"), out = [];
    let i = 0;
    while (i < lines.length) {
      const l = lines[i];
      if (!l.trim()) { i++; continue; }
      if (isHold(l)) { out.push(l.trim()); i++; continue; }
      if (isHeading(l)) {
        const level = l.match(/^#+/)[0].length;
        out.push(level === 1 ? `<h2>${l.replace(/^#+\s*/, "")}</h2>` : `<h3>${l.replace(/^#+\s*/, "")}</h3>`);
        i++; continue;
      }
      if (isRule(l)) { out.push("<hr>"); i++; continue; }
      if (isRow(l) && i + 1 < lines.length && isDivider(lines[i + 1])) {
        const head = cells(l);
        i += 2;
        const rows = [];
        while (i < lines.length && isRow(lines[i])) rows.push(cells(lines[i++]));
        out.push('<div class="table"><table><thead><tr>' + head.map((c) => `<th>${c}</th>`).join("") + "</tr></thead><tbody>"
          + rows.map((r) => "<tr>" + head.map((_, k) => `<td>${r[k] ?? ""}</td>`).join("") + "</tr>").join("") + "</tbody></table></div>");
        continue;
      }
      if (isQuote(l)) {
        const q = [];
        while (i < lines.length && isQuote(lines[i])) q.push(lines[i++].replace(/^\s*&gt; ?/, ""));
        out.push(`<blockquote>${q.join("<br>")}</blockquote>`);
        continue;
      }
      if (isUL(l) || isOL(l)) {
        const ordered = isOL(l), group = [];
        while (i < lines.length && lines[i].trim() && (ordered ? isOL(lines[i]) : isUL(lines[i]) || (/^\s{2,}\S/.test(lines[i]) && !isOL(lines[i])))) group.push(lines[i++]);
        out.push(list(group, ordered));
        continue;
      }
      const para = [];
      while (i < lines.length && lines[i].trim() && !(para.length && startsBlock(lines[i], lines[i + 1]))) para.push(lines[i++].trim());
      out.push(`<p>${para.join("<br>")}</p>`);
    }
    return out.join("");
  }

  function render(src) {
    const code = [], math = [];
    let s = src.replace(/\r\n/g, "\n");
    // Code first (it may hold $ or *), then math, so Markdown can't touch either.
    s = s.replace(/```[\w+-]*\n?([\s\S]*?)```/g, (_, c) => { code.push(`<pre><code>${esc(c.replace(/\n$/, ""))}</code></pre>`); return `\n\u0002${code.length - 1}\u0002\n`; });
    s = s.replace(/\\\$/g, "\u0001");  // an escaped dollar is money, not math
    s = s.replace(/\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]/g, (_, a, b) => { math.push(tex(a || b, true)); return `\u0000${math.length - 1}\u0000`; })
         .replace(/\$(?=\S)([^$\n]*?\S)\$(?!\d)|\\\(([\s\S]+?)\\\)/g, (_, a, b) => { math.push(tex(a || b, false)); return `\u0000${math.length - 1}\u0000`; });
    s = inline(esc(s));
    return blocks(s)
      .replace(/\u0002(\d+)\u0002/g, (_, k) => code[+k])
      .replace(/\u0000(\d+)\u0000/g, (_, k) => math[+k])
      .replace(/\u0001/g, "&#36;");
  }

  return { render, tex };
})();
