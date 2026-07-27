import Foundation
import CoreGraphics
import ImageIO

// Headless Chrome CLI image renderer (TS `browserRenderer.ts` parity without puppeteer).
//
// Launch: `chrome --headless=new --disable-gpu --no-sandbox --screenshot=PATH
//          --window-size=W,H file://HTML`
// Mermaid: inject local mermaid.min.js (never CDN). Caps + concurrency match TS.
// render() NEVER throws — any failure returns nil → raw markdown fallback.

public let RENDER_TIMEOUT_MS: Int = 15_000
public let MAX_BLOCK_CHARS: Int = 20_000
public let MAX_TABLE_CELLS: Int = 2_000
public let MAX_CONCURRENT_RENDERS: Int = 2

/// Optional seams for tests (Process launch + filesystem).
public struct BrowserImageRendererDeps: Sendable {
    public var executablePath: String?
    public var findChrome: @Sendable () -> String?
    public var mermaidJsPath: @Sendable () -> String?
    /// Run chrome; return true when screenshot file was produced.
    public var runChrome: @Sendable (
        _ executable: String,
        _ args: [String],
        _ timeoutMs: Int
    ) async -> Bool
    public var logger: (@Sendable (String) -> Void)?

    public init(
        executablePath: String? = nil,
        findChrome: @escaping @Sendable () -> String? = { DiscordAgentBridge.findChrome() },
        mermaidJsPath: @escaping @Sendable () -> String? = { resolveMermaidJsPath() },
        runChrome: (@Sendable (String, [String], Int) async -> Bool)? = nil,
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        self.executablePath = executablePath
        self.findChrome = findChrome
        self.mermaidJsPath = mermaidJsPath
        self.runChrome = runChrome ?? { exe, args, timeoutMs in
            await defaultRunChrome(executable: exe, args: args, timeoutMs: timeoutMs)
        }
        self.logger = logger
    }
}

/// Locate mermaid.min.js: env `DAB_MERMAID_JS` → repo node_modules → `~/.dab/render/`.
public func resolveMermaidJsPath(
    env: [String: String] = ProcessInfo.processInfo.environment,
    cwd: String = FileManager.default.currentDirectoryPath,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    if let p = env["DAB_MERMAID_JS"], !p.isEmpty, fileExists(p) { return p }
    // Walk up from cwd for monorepo / package root.
    var dir = URL(fileURLWithPath: cwd, isDirectory: true)
    let fm = FileManager.default
    for _ in 0..<12 {
        let candidate = dir
            .appendingPathComponent("node_modules/mermaid/dist/mermaid.min.js", isDirectory: false)
            .path
        if fileExists(candidate) { return candidate }
        if let root = findRepoRoot(startingAt: dir) {
            let fromRoot = root
                .appendingPathComponent("node_modules/mermaid/dist/mermaid.min.js")
                .path
            if fileExists(fromRoot) { return fromRoot }
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    let bundled = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".dab/render/mermaid.min.js")
    if fileExists(bundled) { return bundled }
    // Silence unused when fm only used for existence via fileExists.
    _ = fm
    return nil
}

private func defaultRunChrome(executable: String, args: [String], timeoutMs: Int) async -> Bool {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                cont.resume(returning: false)
                return
            }
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
            while proc.isRunning {
                if Date() > deadline {
                    proc.terminate()
                    // Brief grace then force-kill.
                    Thread.sleep(forTimeInterval: 0.3)
                    if proc.isRunning { proc.interrupt() }
                    cont.resume(returning: false)
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            cont.resume(returning: proc.terminationStatus == 0)
        }
    }
}

/// Headless-Chrome-backed PNG renderer. Actor serializes concurrency (max 2).
public actor BrowserImageRenderer {
    private let deps: BrowserImageRendererDeps
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(deps: BrowserImageRendererDeps = BrowserImageRendererDeps()) {
        self.deps = deps
    }

    public init(executablePath: String?) {
        self.deps = BrowserImageRendererDeps(executablePath: executablePath)
    }

    /// ImageRenderFn box for `deliverAnswer`.
    public nonisolated var asRenderFn: ImageRenderFn {
        { seg in await self.render(seg) }
    }

    public func close() async {
        // CLI path holds no warm browser; nothing to release.
    }

    public func render(_ seg: RenderableSegment) async -> RenderedImage? {
        let raw = seg.raw
        if raw.count > MAX_BLOCK_CHARS { return nil }
        if case .table(let source) = seg, tableCellCount(source) > MAX_TABLE_CELLS {
            return nil
        }
        await acquire()
        let result: RenderedImage?
        switch seg {
        case .table(let source):
            result = await renderTable(source)
        case .mermaid(let code):
            result = await renderMermaid(code)
        }
        releaseSlot()
        return result
    }

    /// Acquire one render slot (cap = MAX_CONCURRENT_RENDERS). Waiters are FIFO.
    private func acquire() async {
        if active < MAX_CONCURRENT_RENDERS {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
        // Handed a slot by releaseSlot (active stays at cap during handoff).
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            return
        }
        active = max(0, active - 1)
    }

    private func renderTable(_ tableMd: String) async -> RenderedImage? {
        let html = buildTableHtml(tableMd)
        return await screenshot(html: html, name: "table.png", extraArgs: [])
    }

    private func renderMermaid(_ code: String) async -> RenderedImage? {
        guard let mermaidPath = deps.mermaidJsPath() else {
            deps.logger?("mermaid.min.js not found (set DAB_MERMAID_JS)")
            return nil
        }
        let fileURL = URL(fileURLWithPath: mermaidPath).absoluteString
        let html = buildMermaidRenderHtml(code: code, mermaidJsURL: fileURL)
        // Wider viewport than the table default: wide/content-heavy diagrams need room to
        // reach their natural size (HtmlTemplates.swift's block-layout fix lets mermaid's own
        // `max-width` cap do the rest — small diagrams stay small, only wide ones grow).
        // Module top-level await is covered by load; virtual-time helps slow diagrams.
        return await screenshot(
            html: html,
            name: "diagram.png",
            extraArgs: ["--virtual-time-budget=10000"],
            windowSize: "2600,1800"
        )
    }

    private func screenshot(
        html: String, name: String, extraArgs: [String], windowSize: String = "1400,900"
    ) async -> RenderedImage? {
        guard let exe = deps.executablePath ?? deps.findChrome() else {
            deps.logger?("chrome executable not found")
            return nil
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("dab-render-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? fm.removeItem(at: tmp) }

        let htmlURL = tmp.appendingPathComponent("page.html")
        let pngURL = tmp.appendingPathComponent("out.png")
        do {
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        // Chrome writes screenshot next to CWD as "screenshot.png" when given a bare
        // name, or to the absolute path we pass.
        var args = [
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--hide-scrollbars",
            "--window-size=\(windowSize)",
            // Retina-quality capture: TS parity `browserRenderer.ts:140`
            // (`deviceScaleFactor: 2`). Logical viewport size is per-caller (`windowSize`
            // above); only the rendered pixel buffer doubles.
            "--force-device-scale-factor=2",
            "--default-background-color=1e2124",
            // Block all outbound network — rendered HTML embeds untrusted user
            // content (Discord table/mermaid text) and must never be able to
            // trigger a real request (SSRF/internal-scan vector). TS parity:
            // `browserRenderer.ts:141-148` (setRequestInterception + offline mode).
            "--proxy-server=http://127.0.0.1:1",
            "--host-resolver-rules=MAP * 0.0.0.0",
            "--screenshot=\(pngURL.path)",
        ]
        args.append(contentsOf: extraArgs)
        args.append(htmlURL.absoluteString)

        let ok = await deps.runChrome(exe, args, RENDER_TIMEOUT_MS)
        guard ok, fm.fileExists(atPath: pngURL.path) else {
            deps.logger?("chrome screenshot failed for \(name)")
            return nil
        }
        guard let data = try? Data(contentsOf: pngURL), !data.isEmpty else {
            return nil
        }
        // PNG magic
        if data.count < 8 || data.prefix(4) != Data([0x89, 0x50, 0x4E, 0x47]) {
            deps.logger?("screenshot is not a PNG")
            return nil
        }
        // Chrome captures its whole viewport. Remove only the uniform page background so
        // Discord receives the rendered table/diagram, not a 1400×900 document screenshot.
        return RenderedImage(data: cropRenderedContent(data) ?? data, name: name)
    }
}

private let renderBackground = (r: UInt8(0x1e), g: UInt8(0x21), b: UInt8(0x24))

func renderContentCropRect(pixels: Data, width: Int, height: Int, bytesPerRow: Int) -> CGRect? {
    guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }
    var minX = width, minY = height, maxX = -1, maxY = -1
    pixels.withUnsafeBytes { raw in
        guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for y in 0..<height {
            for x in 0..<width {
                let p = bytes + y * bytesPerRow + x * 4
                // Two levels tolerate Chrome's color-management/alpha rounding at the edge.
                if abs(Int(p[0]) - Int(renderBackground.r)) > 2 ||
                    abs(Int(p[1]) - Int(renderBackground.g)) > 2 ||
                    abs(Int(p[2]) - Int(renderBackground.b)) > 2
                {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    // Pixel buffer is now captured at 2x device scale (`--force-device-scale-factor=2`),
    // so padding must double too to keep the same ~16 CSS-px visual margin.
    let padding = 32
    let x = max(0, minX - padding), y = max(0, minY - padding)
    let right = min(width, maxX + padding + 1), bottom = min(height, maxY + padding + 1)
    return CGRect(x: x, y: y, width: right - x, height: bottom - y)
}

private func cropRenderedContent(_ png: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width, height = image.height, row = width * 4
    var pixels = Data(count: row * height)
    guard let context = CGContext(
        data: pixels.withUnsafeMutableBytes { $0.baseAddress }, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let rect = renderContentCropRect(pixels: pixels, width: width, height: height, bytesPerRow: row),
          let cropped = image.cropping(to: rect)
    else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
