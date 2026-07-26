import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("ChromiumProvisioner")
struct ChromiumProvisionerTests {
    private func tmpCache() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-chromium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installedWhenSystemChromePresent() async throws {
        let cache = try tmpCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let p = ChromiumProvisioner(deps: ChromiumProvisionerDeps(
            cacheDir: cache.path,
            systemChrome: { "/usr/bin/google-chrome" }
        ))
        #expect(await p.isInstalled())
        #expect(await p.executablePath() == "/usr/bin/google-chrome")
    }

    @Test func notInstalledWithEmptyCacheAndNoSystem() async throws {
        let cache = try tmpCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let p = ChromiumProvisioner(deps: ChromiumProvisionerDeps(
            cacheDir: cache.path,
            systemChrome: { nil }
        ))
        #expect(await p.isInstalled() == false)
        #expect(await p.executablePath() == nil)
    }

    @Test func detectsProvisionedLinuxLayout() async throws {
        let cache = try tmpCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let exe = cache
            .appendingPathComponent("chrome/linux-123/chrome-linux64/chrome")
        try FileManager.default.createDirectory(
            at: exe.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/true\n".write(to: exe, atomically: true, encoding: .utf8)
        let p = ChromiumProvisioner(deps: ChromiumProvisionerDeps(
            cacheDir: cache.path,
            systemChrome: { nil }
        ))
        #expect(await p.isInstalled())
        #expect(await p.executablePath() == exe.path)
    }

    @Test func installRunsProvisionAndReportsProgress() async throws {
        let cache = try tmpCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let seen = LockedBox<[Int]>([])
        let provisionFn: ChromiumProvisionFn = { cacheDir, onProgress in
            onProgress?(50)
            let exe = (cacheDir as NSString)
                .appendingPathComponent("chrome/linux-123/chrome-linux64/chrome")
            try FileManager.default.createDirectory(
                atPath: (exe as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try "#!/bin/true\n".write(toFile: exe, atomically: true, encoding: .utf8)
            onProgress?(100)
        }
        let p = ChromiumProvisioner(deps: ChromiumProvisionerDeps(
            cacheDir: cache.path,
            systemChrome: { nil },
            provisionFn: provisionFn
        ))
        let out = try await p.install { pct in
            seen.withLock { $0.append(pct) }
        }
        #expect(out.contains("chrome-linux64"))
        #expect(seen.withLock { $0 } == [50, 100])
    }

    @Test func installShortCircuitsWhenSystemChromeExists() async throws {
        let cache = try tmpCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let provisionCalled = LockedBox(false)
        let p = ChromiumProvisioner(deps: ChromiumProvisionerDeps(
            cacheDir: cache.path,
            systemChrome: { "/usr/bin/google-chrome" },
            provisionFn: { _, _ in provisionCalled.withLock { $0 = true } }
        ))
        #expect(try await p.install() == "/usr/bin/google-chrome")
        #expect(provisionCalled.withLock { $0 } == false)
    }

    @Test func concurrentInstallJoinsSingleProvision() async throws {
        let cache = try tmpCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let gate = AsyncGate()
        let calls = LockedBox(0)
        let provisionFn: ChromiumProvisionFn = { cacheDir, _ in
            calls.withLock { $0 += 1 }
            await gate.wait()
            let exe = (cacheDir as NSString)
                .appendingPathComponent("chrome/linux-123/chrome-linux64/chrome")
            try FileManager.default.createDirectory(
                atPath: (exe as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try "#!/bin/true\n".write(toFile: exe, atomically: true, encoding: .utf8)
        }
        let p = ChromiumProvisioner(deps: ChromiumProvisionerDeps(
            cacheDir: cache.path,
            systemChrome: { nil },
            provisionFn: provisionFn
        ))
        async let first = p.install()
        async let second = p.install()
        // Let both hit the in-flight guard.
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.release()
        let a = try await first
        let b = try await second
        #expect(a == b)
        #expect(a.contains("chrome-linux64"))
        #expect(calls.withLock { $0 } == 1)
        // Settled → short-circuit on existing executable.
        #expect(try await p.install() == a)
        #expect(calls.withLock { $0 } == 1)
    }
}

/// Tiny async gate for concurrent-install tests.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func release() {
        isOpen = true
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}
