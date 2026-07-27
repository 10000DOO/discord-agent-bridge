import Foundation

// Segment model + ImageRenderer port (TS `src/discord/render/segment.ts`).
// Renderers consume ONLY these types; BrowserImageRenderer implements the port via injection.

/// Ordered answer piece after `splitAnswerSegments`.
public enum AnswerSegment: Sendable, Equatable {
    case text(String)
    /// Original GFM table markdown — raw-text fallback when render fails/skips.
    case table(source: String)
    case mermaid(code: String)

    public var kind: String {
        switch self {
        case .text: return "text"
        case .table: return "table"
        case .mermaid: return "mermaid"
        }
    }
}

/// Table or mermaid block ready for PNG render (never text).
public enum RenderableSegment: Sendable, Equatable {
    case table(source: String)
    case mermaid(code: String)

    public var kind: String {
        switch self {
        case .table: return "table"
        case .mermaid: return "mermaid"
        }
    }

    public var raw: String {
        switch self {
        case .table(let source): return source
        case .mermaid(let code): return code
        }
    }

    public init?(_ seg: AnswerSegment) {
        switch seg {
        case .table(let source): self = .table(source: source)
        case .mermaid(let code): self = .mermaid(code: code)
        case .text: return nil
        }
    }
}

/// In-memory PNG ready to attach (no temp file for the Discord client path).
public struct RenderedImage: Sendable, Equatable {
    public var data: Data
    public var name: String

    public init(data: Data, name: String) {
        self.data = data
        self.name = name
    }
}

/// Render a table/mermaid segment → PNG. Returns nil on any failure/skip — NEVER throws;
/// caller falls back to the block's raw markdown so the answer is never broken.
public typealias ImageRenderFn = @Sendable (RenderableSegment) async -> RenderedImage?

/// Optional shutdown hook for a warm browser / held resources.
public typealias ImageRenderCloseFn = @Sendable () async -> Void
