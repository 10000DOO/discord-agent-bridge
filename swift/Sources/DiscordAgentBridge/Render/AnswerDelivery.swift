import Foundation

// Common answer-delivery helper (TS `answerDelivery.ts`).
// When `renderImage` is set, GFM tables and ```mermaid``` fences become PNG attachments
// in place (text → image → text); otherwise byte-for-byte `DiscordText.chunkMessage`.

/// One outbound payload: plain text and/or a single file attachment.
public struct DeliverPayload: Sendable, Equatable {
    public var content: String?
    public var fileName: String?
    public var fileData: Data?

    public init(content: String? = nil, fileName: String? = nil, fileData: Data? = nil) {
        self.content = content
        self.fileName = fileName
        self.fileData = fileData
    }

    public static func text(_ s: String) -> DeliverPayload {
        DeliverPayload(content: s)
    }

    public static func file(name: String, data: Data) -> DeliverPayload {
        DeliverPayload(fileName: name, fileData: data)
    }
}

public struct DeliverOptions: Sendable {
    /// Present → render tables/mermaid; absent → text-only (legacy chunkMessage).
    public var renderImage: ImageRenderFn?
    /// Called once per payload, in order.
    public var emit: @Sendable (DeliverPayload) async throws -> Void
    /// When the answer produced nothing but a live sink still exists — clear it (TS sink.edit empty).
    public var clearEmpty: (@Sendable () async -> Void)?

    public init(
        renderImage: ImageRenderFn? = nil,
        emit: @escaping @Sendable (DeliverPayload) async throws -> Void,
        clearEmpty: (@Sendable () async -> Void)? = nil
    ) {
        self.renderImage = renderImage
        self.emit = emit
        self.clearEmpty = clearEmpty
    }
}

private func rawTextForBlock(_ seg: RenderableSegment) -> String {
    switch seg {
    case .mermaid(let code):
        return "```mermaid\n\(code)\n```"
    case .table(let source):
        return source
    }
}

/// Deliver answer text (optionally rendering table/mermaid blocks as PNGs).
/// Never throws from render failures — only `emit` / `clearEmpty` may throw.
public func deliverAnswer(_ text: String, options: DeliverOptions) async throws {
    let emit = options.emit
    let renderImage = options.renderImage

    // No renderer → preserve legacy: chunk whole text.
    guard let renderImage else {
        let chunks = DiscordText.chunkMessage(text)
        if chunks.isEmpty {
            await options.clearEmpty?()
            return
        }
        for chunk in chunks {
            try await emit(.text(chunk))
        }
        return
    }

    let segs = splitAnswerSegments(text)
    var emitted = false
    for seg in segs {
        switch seg {
        case .text(let t):
            for chunk in DiscordText.chunkMessage(t) {
                try await emit(.text(chunk))
                emitted = true
            }
        case .table, .mermaid:
            guard let block = RenderableSegment(seg) else { continue }
            if let img = await renderImage(block) {
                try await emit(.file(name: img.name, data: img.data))
                emitted = true
            } else {
                // Render skipped/failed → keep original markdown.
                for chunk in DiscordText.chunkMessage(rawTextForBlock(block)) {
                    try await emit(.text(chunk))
                    emitted = true
                }
            }
        }
    }
    if !emitted {
        await options.clearEmpty?()
    }
}
