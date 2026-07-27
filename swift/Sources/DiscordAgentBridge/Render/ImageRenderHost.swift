import Foundation

// Process-wide image renderer gate (TS SessionWiring.resolveImageRenderer).
// Lazily builds BrowserImageRenderer when render.enabled + chrome available.
// Never throws — any failure degrades to nil (text-only).

public actor ImageRenderHost {
    public static let shared = ImageRenderHost()

    private var renderer: BrowserImageRenderer?
    private var provisioner: ChromiumProvisioner?
    private var configLoad: (@Sendable () async -> AppConfig?)?
    private var disabledByEnv = false

    public init() {}

    /// Wire config + optional env gates at bot boot.
    public func configure(
        configLoad: @escaping @Sendable () async -> AppConfig?,
        cacheDir: String? = nil
    ) {
        self.configLoad = configLoad
        let dir = cacheDir ?? ChromiumProvisioner.defaultCacheDir()
        self.provisioner = ChromiumProvisioner(deps: ChromiumProvisionerDeps(cacheDir: dir))
        // DAB_RENDER=0 forces off; DAB_RENDER=1 forces preference (still needs chrome).
        if ProcessInfo.processInfo.environment["DAB_RENDER"] == "0" {
            disabledByEnv = true
        }
    }

    public func provisionerInstance() -> ChromiumProvisioner? { provisioner }

    /// True when something launchable already exists (system or provisioned) — H6/H7's
    /// "already installed" fast path, without constructing a renderer.
    public func isInstalled() async -> Bool {
        await provisioner?.isInstalled() ?? false
    }

    /// Resolve render fn for a turn/share, or nil when branch is off.
    public func resolveRenderFn() async -> ImageRenderFn? {
        if disabledByEnv { return nil }
        // Optional force-on via env when chrome is present (config may still disable).
        let forceOn = ProcessInfo.processInfo.environment["DAB_RENDER"] == "1"
        let cfg = await configLoad?()
        let enabled = cfg?.render?.enabled ?? true
        if !enabled && !forceOn { return nil }

        let prov = provisioner ?? ChromiumProvisioner(
            deps: ChromiumProvisionerDeps(cacheDir: ChromiumProvisioner.defaultCacheDir())
        )
        if provisioner == nil { provisioner = prov }

        guard await prov.isInstalled() else { return nil }
        let exec = await prov.executablePath()
        if renderer == nil {
            renderer = BrowserImageRenderer(executablePath: exec)
        }
        guard let r = renderer else { return nil }
        return r.asRenderFn
    }

    public func close() async {
        await renderer?.close()
        renderer = nil
    }

    /// Install chromium (config panel /setup). Sets chromium.decision=accepted on success.
    public func install(onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        let prov = provisioner ?? ChromiumProvisioner(
            deps: ChromiumProvisionerDeps(cacheDir: ChromiumProvisioner.defaultCacheDir())
        )
        if provisioner == nil { provisioner = prov }
        let path = try await prov.install(onProgress: onProgress)
        // Invalidate renderer so next resolve picks the new exec path.
        renderer = nil
        return path
    }
}
