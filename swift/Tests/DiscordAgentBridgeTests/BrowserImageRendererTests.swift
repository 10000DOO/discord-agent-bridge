import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("BrowserImageRenderer")
struct BrowserImageRendererTests {
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
}
