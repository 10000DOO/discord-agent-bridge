import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import DiscordAgentBridge

@Suite("BrowserImageRenderer")
struct BrowserImageRendererTests {
    // 2x-scale pixel buffer (padding = 32 device px; was 16 at the old 1x scale).
    @Test func cropBoundsKeepOnlyContentWithPadding() {
        var pixels = Data(repeating: 0, count: 100 * 100 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 0x1e; pixels[i + 1] = 0x21; pixels[i + 2] = 0x24; pixels[i + 3] = 0xff
        }
        let content = (50 * 100 + 50) * 4
        pixels[content] = 0xff
        #expect(renderContentCropRect(pixels: pixels, width: 100, height: 100, bytesPerRow: 400) == CGRect(x: 18, y: 18, width: 65, height: 65))
    }

    @Test func sizeGuardReturnsNilWithoutLaunchingChrome() async {
        let launched = LockedBox(false)
        let big = String(repeating: "x", count: MAX_BLOCK_CHARS + 1)
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            findChrome: { "/fake/chrome" },
            mermaidJsPath: { "/fake/mermaid.min.js" },
            runChrome: { _, _, _ in
                launched.withLock { $0 = true }
                return false
            }
        ))
        let out = await r.render(.table(source: big))
        #expect(out == nil)
        #expect(launched.withLock { $0 } == false)
    }

    @Test func tableCellGuardReturnsNil() async {
        var rows = ["| a | b |", "|---|---|"]
        for i in 0..<(MAX_TABLE_CELLS / 2 + 10) {
            rows.append("| \(i) | \(i) |")
        }
        let launched = LockedBox(false)
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            runChrome: { _, _, _ in
                launched.withLock { $0 = true }
                return false
            }
        ))
        let out = await r.render(.table(source: rows.joined(separator: "\n")))
        #expect(out == nil)
        #expect(launched.withLock { $0 } == false)
    }

    @Test func successfulScreenshotReturnsPng() async throws {
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            runChrome: { _, args, _ in
                guard let shot = args.first(where: { $0.hasPrefix("--screenshot=") }) else {
                    return false
                }
                let path = String(shot.dropFirst("--screenshot=".count))
                try? pngMagic.write(to: URL(fileURLWithPath: path))
                return true
            }
        ))
        let out = await r.render(.table(source: "| a |\n|---|\n| 1 |"))
        #expect(out?.name == "table.png")
        #expect(out?.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func screenshotArgsBlockOutboundNetwork() async throws {
        let capturedArgs = LockedBox<[String]?>(nil)
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            runChrome: { _, args, _ in
                capturedArgs.withLock { $0 = args }
                guard let shot = args.first(where: { $0.hasPrefix("--screenshot=") }) else {
                    return false
                }
                let path = String(shot.dropFirst("--screenshot=".count))
                try? pngMagic.write(to: URL(fileURLWithPath: path))
                return true
            }
        ))
        _ = await r.render(.table(source: "| a |\n|---|\n| 1 |"))
        let args = try #require(capturedArgs.withLock { $0 })
        #expect(args.contains("--proxy-server=http://127.0.0.1:1"))
        #expect(args.contains("--host-resolver-rules=MAP * 0.0.0.0"))
    }

    @Test func screenshotArgsUseDoubleDeviceScaleFactor() async throws {
        let capturedArgs = LockedBox<[String]?>(nil)
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            runChrome: { _, args, _ in
                capturedArgs.withLock { $0 = args }
                guard let shot = args.first(where: { $0.hasPrefix("--screenshot=") }) else {
                    return false
                }
                let path = String(shot.dropFirst("--screenshot=".count))
                try? pngMagic.write(to: URL(fileURLWithPath: path))
                return true
            }
        ))
        _ = await r.render(.table(source: "| a |\n|---|\n| 1 |"))
        let args = try #require(capturedArgs.withLock { $0 })
        // TS parity: `browserRenderer.ts:140` deviceScaleFactor 2 with the same logical viewport.
        #expect(args.contains("--force-device-scale-factor=2"))
        #expect(args.contains("--window-size=1400,900"))
    }

    // A 2x-scale Chrome capture writes a 2800x1800 buffer for the same 1400x900 logical
    // viewport (was 1400x900 pre-fix). Uniform background => no crop rect => the renderer
    // returns the raw buffer untouched, so its dimensions are checkable directly.
    @Test func doubleScaleScreenshotProducesDoublePixelDimensions() async throws {
        let width = 1400 * 2, height = 900 * 2
        let png = solidBackgroundPng(width: width, height: height)
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            runChrome: { _, args, _ in
                guard let shot = args.first(where: { $0.hasPrefix("--screenshot=") }) else {
                    return false
                }
                let path = String(shot.dropFirst("--screenshot=".count))
                try? png.write(to: URL(fileURLWithPath: path))
                return true
            }
        ))
        let out = await r.render(.table(source: "| a |\n|---|\n| 1 |"))
        let data = try #require(out?.data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == width)
        #expect(image.height == height)
    }

    @Test func mermaidRendersAlsoBlockOutboundNetwork() async {
        let capturedArgs = LockedBox<[String]?>(nil)
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            mermaidJsPath: { "/fake/mermaid.min.js" },
            runChrome: { _, args, _ in
                capturedArgs.withLock { $0 = args }
                return false
            }
        ))
        _ = await r.render(.mermaid(code: "flowchart LR\n  A --> B"))
        let args = capturedArgs.withLock { $0 }
        #expect(args?.contains("--proxy-server=http://127.0.0.1:1") == true)
        #expect(args?.contains("--host-resolver-rules=MAP * 0.0.0.0") == true)
    }

    @Test func mermaidWithoutBundleReturnsNil() async {
        let launched = LockedBox(false)
        let r = BrowserImageRenderer(deps: BrowserImageRendererDeps(
            executablePath: "/fake/chrome",
            mermaidJsPath: { nil },
            runChrome: { _, _, _ in
                launched.withLock { $0 = true }
                return false
            }
        ))
        let out = await r.render(.mermaid(code: "flowchart LR\n  A --> B"))
        #expect(out == nil)
        #expect(launched.withLock { $0 } == false)
    }

    @Test func realChromeTableScreenshotWhenAvailable() async throws {
        guard let chrome = findChrome() else { return }
        let r = BrowserImageRenderer(executablePath: chrome)
        let out = await r.render(.table(source: "| Name | Age |\n|---|---|\n| Kim | 30 |"))
        if let out {
            #expect(out.name == "table.png")
            #expect(out.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
            #expect(out.data.count > 100)
        }
    }

    // WO-2: a mermaid diagram wide enough (many long-labeled nodes) that its natural SVG
    // size clears the old table-sized viewport was previously still cropped to a tiny,
    // content-independent box (~300 CSS px) because the mermaid HTML template's
    // `display:inline-block` body/#c left the SVG's `width:100%` unable to resolve against
    // anything. With that CSS fixed to a normal block layout plus a wider mermaid-only
    // viewport, this diagram's crop should grow well past the old 1400x900 (x2 scale =
    // 2800px-wide) ceiling instead of staying pinned to it.
    @Test func realChromeWideMermaidDiagramGrowsPastOldViewportWidth() async throws {
        guard let chrome = findChrome() else { return }
        let ids = (1...15).map { "N\($0)" }
        let defs = ids.map { "\($0)[\"Step \($0): validate and process the customer order thoroughly\"]" }
        let code = "flowchart LR\n  " + ids.joined(separator: " --> ") + "\n  " + defs.joined(separator: "\n  ")
        let r = BrowserImageRenderer(executablePath: chrome)
        let out = await r.render(.mermaid(code: code))
        guard let out else { return } // mermaid.min.js not bundled in this environment; skip like other real-chrome tests.
        let source = try #require(CGImageSourceCreateWithData(out.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 2800)
    }
}

/// A `width`x`height` PNG filled entirely with the renderer's background color, so
/// `renderContentCropRect` finds no content and the raw buffer passes through uncropped.
private func solidBackgroundPng(width: Int, height: Int) -> Data {
    let row = width * 4
    var pixels = Data(count: row * height)
    pixels.withUnsafeMutableBytes { raw in
        guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for i in stride(from: 0, to: row * height, by: 4) {
            bytes[i] = 0x1e; bytes[i + 1] = 0x21; bytes[i + 2] = 0x24; bytes[i + 3] = 0xff
        }
    }
    let context = CGContext(
        data: pixels.withUnsafeMutableBytes { $0.baseAddress }, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}
