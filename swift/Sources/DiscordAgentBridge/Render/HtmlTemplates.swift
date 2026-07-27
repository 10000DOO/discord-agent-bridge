import Foundation

// Pure HTML builders for the render engine (TS `htmlTemplates.ts`).
// Table cells and mermaid source are UNTRUSTED — every interpolation is HTML-escaped.

/// Escape HTML metacharacters (order: & first).
public func escapeHtml(_ s: String) -> String {
    s
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

// Minimal inline markdown inside table cells (code / bold / italic / strike), applied
// AFTER escaping so no raw HTML can slip through.
private func inlineMd(_ s: String) -> String {
    var out = escapeHtml(s)
    out = out.replacingOccurrences(
        of: #"`([^`]+)`"#,
        with: "<code>$1</code>",
        options: .regularExpression
    )
    out = out.replacingOccurrences(
        of: #"\*\*([^*]+)\*\*"#,
        with: "<strong>$1</strong>",
        options: .regularExpression
    )
    out = out.replacingOccurrences(
        of: #"~~([^~]+)~~"#,
        with: "<del>$1</del>",
        options: .regularExpression
    )
    // Single *italic* without matching ** (TS lookbehind/ahead).
    out = replaceItalic(out)
    return out
}

/// Replace `*text*` that is not part of `**`, without Foundation lookbehind (portable).
private func replaceItalic(_ s: String) -> String {
    var result = ""
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        if chars[i] == "*" {
            // Skip ** (already handled as strong) or lone trailing.
            if i + 1 < chars.count && chars[i + 1] == "*" {
                result.append("**")
                i += 2
                continue
            }
            // Find closing * that is not part of **.
            var j = i + 1
            var found: Int?
            while j < chars.count {
                if chars[j] == "*" {
                    let prevIsStar = j > 0 && chars[j - 1] == "*"
                    let nextIsStar = j + 1 < chars.count && chars[j + 1] == "*"
                    if !prevIsStar && !nextIsStar && j > i + 1 {
                        found = j
                        break
                    }
                }
                j += 1
            }
            if let end = found {
                let inner = String(chars[(i + 1)..<end])
                if !inner.contains("*") {
                    result.append("<em>")
                    result.append(inner)
                    result.append("</em>")
                    i = end + 1
                    continue
                }
            }
        }
        result.append(chars[i])
        i += 1
    }
    return result
}

private let darkCSS = """
  * { box-sizing: border-box; }
  body { margin: 0; background: #1e2124; display: inline-block; }
  #c { display: inline-block; padding: 16px; }
  table {
    border-collapse: collapse;
    font: 15px/1.5 "Apple SD Gothic Neo","Malgun Gothic","Noto Sans CJK KR","gg sans",-apple-system,"Segoe UI",sans-serif;
    color: #dbdee1;
  }
  th, td { border: 1px solid #3f4248; padding: 7px 14px; white-space: pre-wrap; text-align: left; }
  th { background: #2b2d31; font-weight: 600; }
  tbody tr:nth-child(2n) { background: #26282c; }
  code { background: #2b2d31; padding: .15em .4em; border-radius: 4px; font-family: ui-monospace,Menlo,monospace; font-size: 90%; }
"""

/// GFM table markdown → full dark-themed HTML document (single `<table>` in `#c`).
public func buildTableHtml(_ tableMd: String) -> String {
    let rows = tableMd.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let header = splitRow(rows.first ?? "")
    let aligns: [String] = {
        guard rows.count > 1 else { return [] }
        return splitRow(rows[1]).map { c in
            let l = c.hasPrefix(":")
            let r = c.hasSuffix(":")
            if l && r { return "center" }
            if r { return "right" }
            if l { return "left" }
            return ""
        }
    }()
    let body = rows.dropFirst(2).map { splitRow(String($0)) }
    func align(_ i: Int) -> String {
        guard i < aligns.count, !aligns[i].isEmpty else { return "" }
        return " style=\"text-align:\(aligns[i])\""
    }
    let th = header.enumerated().map { i, h in
        "<th\(align(i))>\(inlineMd(h))</th>"
    }.joined()
    let trs = body.map { cells in
        let tds = cells.enumerated().map { i, c in
            "<td\(align(i))>\(inlineMd(c))</td>"
        }.joined()
        return "<tr>\(tds)</tr>"
    }.joined()
    let table = "<table><thead><tr>\(th)</tr></thead><tbody>\(trs)</tbody></table>"
    return "<!doctype html><html><head><meta charset=\"utf-8\"><style>\(darkCSS)</style></head><body><div id=\"c\">\(table)</div></body></html>"
}

/// Empty dark page for mermaid; diagram source is NOT inlined here (TS parity shell).
/// CLI renderer uses `buildMermaidRenderHtml` which embeds script + escaped source.
public func buildMermaidHtml() -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;background:#1e2124;display:inline-block;}
        #c{display:inline-block;padding:16px;}
        #c svg{display:block;}
    </style></head><body><div id="c"></div></body></html>
    """
}

/// JSON-string literal for embedding untrusted text into a `<script>` (quotes, newlines, U+2028/9).
public func jsonStringLiteral(_ s: String) -> String {
    var out = "\""
    for ch in s.unicodeScalars {
        switch ch.value {
        case 0x22: out += "\\\""          // "
        case 0x5C: out += "\\\\"          // \
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00..<0x20: out += String(format: "\\u%04x", ch.value)
        case 0x2028, 0x2029: out += String(format: "\\u%04x", ch.value)
        case 0x3C: out += "\\u003c"       // <  — avoid `</script>` breakout
        case 0x3E: out += "\\u003e"
        default: out.unicodeScalars.append(ch)
        }
    }
    out += "\""
    return out
}

/// Self-contained mermaid page for headless Chrome CLI screenshot.
/// `mermaidJsURL` is a `file://` URL to local mermaid.min.js (never a CDN).
/// `code` is JSON-string-escaped into the module script; mermaid uses securityLevel:'strict'.
public func buildMermaidRenderHtml(code: String, mermaidJsURL: String) -> String {
    let codeJSON = jsonStringLiteral(code)
    let srcAttr = escapeHtml(mermaidJsURL)
    return """
    <!doctype html><html><head><meta charset="utf-8"><style>
      /* NOT inline-block: mermaid's SVG is `width:100%` + inline `max-width:<natural>px`.
         An inline-block (shrink-to-fit) ancestor can't resolve that percentage, so Chrome
         falls back to the ~300px replaced-element default REGARDLESS OF VIEWPORT SIZE —
         wide diagrams then cram all their nodes into that fixed box and text shrinks with
         them. A normal block body/#c gives the SVG a real (viewport-sized) width to
         resolve against, so it grows up to its own natural size instead. */
      body{margin:0;background:#1e2124;}
      #c{padding:16px;}
      #c svg{display:block;}
    </style>
    <script src="\(srcAttr)"></script>
    </head><body><div id="c"></div>
    <script type="module">
      const src = \(codeJSON);
      const m = window.mermaid;
      m.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
      const { svg } = await m.render('g0', src);
      document.getElementById('c').innerHTML = svg;
    </script>
    </body></html>
    """
}
