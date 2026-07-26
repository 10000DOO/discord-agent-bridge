import Testing
@testable import DiscordAgentBridge

@Suite("HtmlTemplates")
struct HtmlTemplatesTests {
    @Test func escapeHtmlMetacharacters() {
        #expect(escapeHtml("<script>&\"") == "&lt;script&gt;&amp;&quot;")
    }

    @Test func buildTableHtmlRendersHeaderAndBody() {
        let html = buildTableHtml("| Name | Age |\n|---|---|\n| Kim | 30 |")
        #expect(html.contains("<th>Name</th>"))
        #expect(html.contains("<td>Kim</td>"))
        #expect(html.contains("<td>30</td>"))
    }

    @Test func buildTableHtmlEscapesUntrustedCells() {
        let html = buildTableHtml("| x |\n|---|\n| <img src=x onerror=alert(1)> |")
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    @Test func buildTableHtmlAppliesAlignment() {
        let html = buildTableHtml("| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
        #expect(html.contains("text-align:left"))
        #expect(html.contains("text-align:center"))
        #expect(html.contains("text-align:right"))
    }

    @Test func buildMermaidHtmlEmptyDarkContainer() {
        let html = buildMermaidHtml()
        #expect(html.contains("<div id=\"c\"></div>"))
        #expect(html.contains("background:#1e2124"))
    }

    @Test func buildMermaidRenderHtmlEscapesCodeAsJson() {
        let html = buildMermaidRenderHtml(
            code: "flowchart LR\n  A --> B</script>",
            mermaidJsURL: "file:///tmp/mermaid.min.js"
        )
        #expect(html.contains("securityLevel: 'strict'"))
        #expect(html.contains("file:///tmp/mermaid.min.js"))
        // Source is JSON-string embedded; `<` becomes \u003c so </script> cannot break out.
        #expect(html.contains("\\u003c"))
        #expect(!html.contains("--> B</script>"))
    }

    @Test func jsonStringLiteralEscapesQuotesAndNewlines() {
        #expect(jsonStringLiteral("a\"b\nc") == "\"a\\\"b\\nc\"")
    }
}
