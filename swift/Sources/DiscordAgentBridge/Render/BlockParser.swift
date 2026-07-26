import Foundation

// Pure answer-text → AnswerSegment[] parser (TS `blockParser.ts`). No Discord / Chrome.
// FALSE-POSITIVE avoidance: fenced code is never a table; stray pipes without a delimiter
// row are never a table; delimiter cell count must match the header.

// A GFM table delimiter row: `|---|:--:|`, `--- | :--- | ---:`, etc.
private let delimRowRegex: NSRegularExpression = {
    try! NSRegularExpression(
        pattern: #"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$"#
    )
}()

// A single delimiter CELL: `-`+ with optional leading/trailing `:` alignment marker.
private let delimCellRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: #"^:?-{1,}:?$"#)
}()

// A fence open line: ``` or ~~~ with an optional info string (language).
private let fenceRegex: NSRegularExpression = {
    try! NSRegularExpression(pattern: #"^(\s*)(`{3,}|~{3,})\s*([^\s`~]*)"#)
}()

private func fullMatch(_ re: NSRegularExpression, _ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, options: [], range: range) else { return false }
    return m.range.location == 0 && m.range.length == range.length
}

private func isTableRow(_ line: String) -> Bool {
    line.contains("|") && !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Split a table row into trimmed cells, honoring `\|` escapes and leading/trailing pipes.
public func splitRow(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("|") { s = String(s.dropFirst()) }
    if s.hasSuffix("|") && !s.hasSuffix("\\|") { s = String(s.dropLast()) }
    var cells: [String] = []
    var cur = ""
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "|" {
            cur.append("|")
            i += 2
            continue
        }
        if chars[i] == "|" {
            cells.append(cur)
            cur = ""
            i += 1
            continue
        }
        cur.append(chars[i])
        i += 1
    }
    cells.append(cur)
    return cells.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// True when `delim` is a valid GFM delimiter row FOR `header` (cell count + pure markers).
private func isTableDelimiterFor(header: String, delim: String) -> Bool {
    let headerCells = splitRow(header)
    let delimCells = splitRow(delim)
    guard headerCells.count == delimCells.count else { return false }
    return delimCells.allSatisfy { fullMatch(delimCellRegex, $0) }
}

/// Number of cells (body rows × columns) in a table block — size guard.
public func tableCellCount(_ tableMd: String) -> Int {
    let rows = tableMd.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if rows.count < 2 { return 0 }
    let cols = splitRow(rows[0]).count
    // Exclude BOTH the header and the delimiter row from the body count.
    return max(0, rows.count - 2) * cols
}

/// Split answer text into an ordered sequence of text / table / mermaid segments.
/// Adjacent text is merged; block↔text order is preserved for text → image → text delivery.
public func splitAnswerSegments(_ text: String) -> [AnswerSegment] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var segments: [AnswerSegment] = []
    var buf: [String] = []

    func flushText() {
        guard !buf.isEmpty else { return }
        let joined = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty {
            segments.append(.text(joined))
        }
        buf = []
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let nsLine = line as NSString
        let full = NSRange(location: 0, length: nsLine.length)
        if let fence = fenceRegex.firstMatch(in: line, options: [], range: full),
           fence.numberOfRanges >= 4
        {
            let markerRange = fence.range(at: 2)
            let infoRange = fence.range(at: 3)
            let markerStr = nsLine.substring(with: markerRange)
            let markerChar = markerStr.first ?? "`"
            let info = (infoRange.location != NSNotFound
                ? nsLine.substring(with: infoRange)
                : "").lowercased()

            var body: [String] = []
            var j = i + 1
            let closePattern = markerChar == "`" ? #"^\s*`{3,}\s*$"# : #"^\s*~{3,}\s*$"#
            let closeRe = try! NSRegularExpression(pattern: closePattern)
            while j < lines.count {
                if fullMatch(closeRe, lines[j]) { break }
                body.append(lines[j])
                j += 1
            }
            if info == "mermaid" {
                flushText()
                segments.append(.mermaid(code: body.joined(separator: "\n")))
            } else {
                // Any other fence stays verbatim in text (pipes must NOT become a table).
                buf.append(line)
                buf.append(contentsOf: body)
                if j < lines.count { buf.append(lines[j]) }
            }
            i = j // skip past closing fence (or EOF)
            i += 1
            continue
        }

        // GFM table: pipe row + delimiter with matching cell count / markers.
        if isTableRow(line),
           i + 1 < lines.count,
           fullMatch(delimRowRegex, lines[i + 1]),
           isTableDelimiterFor(header: line, delim: lines[i + 1])
        {
            var tbl = [line, lines[i + 1]]
            var j = i + 2
            while j < lines.count {
                if !isTableRow(lines[j]) { break }
                tbl.append(lines[j])
                j += 1
            }
            flushText()
            segments.append(.table(source: tbl.joined(separator: "\n")))
            i = j
            continue
        }

        buf.append(line)
        i += 1
    }
    flushText()
    return segments
}
