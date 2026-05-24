import Foundation

public enum StandalonePlatform: String, Sendable, Equatable, Codable {
    case unix
    case windows
}

public enum InstallContext: Sendable, Equatable, Codable {
    case standalone(releaseDir: String, resourcesDir: String?, platform: StandalonePlatform)
    case npm
    case bun
    case brew
    case other

    public var kind: String {
        switch self {
        case .standalone: return "standalone"
        case .npm: return "npm"
        case .bun: return "bun"
        case .brew: return "brew"
        case .other: return "other"
        }
    }

    public static func current(
        codexHome: String? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> InstallContext {
        fromExecutable(
            isMacOS: {
                #if os(macOS)
                return true
                #else
                return false
                #endif
            }(),
            currentExecutable: Bundle.main.executablePath ?? CommandLine.arguments.first,
            managedByNpm: env["CODEX_MANAGED_BY_NPM"] != nil,
            managedByBun: env["CODEX_MANAGED_BY_BUN"] != nil,
            codexHome: codexHome ?? env["CODEX_HOME"])
    }

    public static func fromExecutable(
        isMacOS: Bool,
        currentExecutable: String?,
        managedByNpm: Bool,
        managedByBun: Bool,
        codexHome: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: (String) -> Bool = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir)
                && isDir.boolValue
        },
        canonicalize: (String) -> String? = { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
    ) -> InstallContext {
        if managedByNpm { return .npm }
        if managedByBun { return .bun }

        if let executable = currentExecutable,
           let standalone = standaloneContext(executable: executable,
                                              codexHome: codexHome,
                                              fileExists: fileExists,
                                              isDirectory: isDirectory,
                                              canonicalize: canonicalize) {
            return standalone
        }

        if isMacOS, let executable = currentExecutable,
           executable.hasPrefix("/opt/homebrew") || executable.hasPrefix("/usr/local") {
            return .brew
        }

        return .other
    }

    public func rgCommand(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        switch self {
        case .standalone(_, let resourcesDir?, _):
            let bundled = resourcesDir + "/" + Self.defaultRgCommand
            return fileExists(bundled) ? bundled : Self.defaultRgCommand
        case .standalone, .npm, .bun, .brew, .other:
            return Self.defaultRgCommand
        }
    }

    public static var defaultRgCommand: String {
        #if os(Windows)
        return "rg.exe"
        #else
        return "rg"
        #endif
    }

    private static func standaloneContext(
        executable: String,
        codexHome: String?,
        fileExists: (String) -> Bool,
        isDirectory: (String) -> Bool,
        canonicalize: (String) -> String?
    ) -> InstallContext? {
        guard let codexHome,
              fileExists(executable),
              let canonicalExecutable = canonicalize(executable),
              let canonicalCodexHome = canonicalize(codexHome) else {
            return nil
        }
        let releaseDir = URL(fileURLWithPath: canonicalExecutable)
            .deletingLastPathComponent()
            .standardizedFileURL.path
        let releasesRoot = URL(fileURLWithPath: canonicalCodexHome)
            .appendingPathComponent("packages", isDirectory: true)
            .appendingPathComponent("standalone", isDirectory: true)
            .appendingPathComponent("releases", isDirectory: true)
            .standardizedFileURL.path
        guard releaseDir == releasesRoot || releaseDir.hasPrefix(releasesRoot + "/") else {
            return nil
        }
        let resourcesDir = releaseDir + "/codex-resources"
        return .standalone(
            releaseDir: releaseDir,
            resourcesDir: isDirectory(resourcesDir) ? resourcesDir : nil,
            platform: {
                #if os(Windows)
                return .windows
                #else
                return .unix
                #endif
            }())
    }
}
