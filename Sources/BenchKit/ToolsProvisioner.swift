import Foundation

/// Provisions static `rg` (ripgrep) and `fd` arm64-linux binaries into a host
/// cache dir that the agent's work container mounts at `/opt/cbtools`. Their
/// absence forced ~50+ manual `read_file` calls per task (a big iteration/cost
/// tax); giving the agent fast search cuts exploration. Entirely best-effort —
/// if the one-time download fails (offline, rate-limited), runs proceed and the
/// agent falls back to `grep`/`find` (per the prompt).
public actor ToolsProvisioner {
    public static let shared = ToolsProvisioner()
    private var provisioned: URL?

    // Pinned static aarch64 linux (glibc — matches the Debian/Ubuntu mars-base) builds.
    private static let rgURL = "https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz"
    private static let fdURL = "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-aarch64-unknown-linux-gnu.tar.gz"

    /// Returns the host dir containing `rg`/`fd` (mount at `/opt/cbtools`), or
    /// nil if neither could be provisioned.
    public func ensure(cacheRoot: URL, log: @escaping @Sendable (String) -> Void) async -> URL? {
        if let p = provisioned { return p }
        let dir = cacheRoot.appendingPathComponent("cbtools", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rg = dir.appendingPathComponent("rg")
        let fd = dir.appendingPathComponent("fd")

        if !fm.isExecutableFile(atPath: rg.path) {
            if await Self.fetch(Self.rgURL, binaryName: "rg", into: rg) { log("provisioned rg → \(rg.path)") }
            else { log("rg provisioning skipped (download failed; agent will use grep)") }
        }
        if !fm.isExecutableFile(atPath: fd.path) {
            _ = await Self.fetch(Self.fdURL, binaryName: "fd", into: fd)
        }
        let result: URL? = (fm.isExecutableFile(atPath: rg.path) || fm.isExecutableFile(atPath: fd.path)) ? dir : nil
        provisioned = result
        return result
    }

    private static func fetch(_ url: String, binaryName: String, into dest: URL) async -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cbtool-\(UUID().uuidString)")
        let script = """
        set -e
        mkdir -p '\(tmp.path)'
        curl -fsSL '\(url)' -o '\(tmp.path)/a.tar.gz'
        tar -xzf '\(tmp.path)/a.tar.gz' -C '\(tmp.path)'
        bin=$(find '\(tmp.path)' -type f -name '\(binaryName)' | head -1)
        [ -n "$bin" ] || { echo no-binary; exit 1; }
        cp "$bin" '\(dest.path)'
        chmod +x '\(dest.path)'
        """
        let r = await Subprocess.run("/bin/bash", ["-lc", script], timeout: .seconds(120))
        try? FileManager.default.removeItem(at: tmp)
        return r.ok && FileManager.default.isExecutableFile(atPath: dest.path)
    }
}
