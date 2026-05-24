import Foundation
import WireProtocol

/// Faithful default responses for Codex methods dispatched through
/// `ClientRequest.generic` (peripheral or experimental endpoints the harness
/// does not deeply back yet). Shapes match `app-server-protocol` response
/// types so clients receive a valid, parseable result rather than `-32601`.
public enum GenericResponses {

    private static let emptyDataCursor: JSONValue =
        .object(["data": .array([]), "nextCursor": .null])
    private static let emptyDataCursorBackwards: JSONValue =
        .object(["data": .array([]), "nextCursor": .null, "backwardsCursor": .null])
    private static let empty: JSONValue = .object([:])
    private static let minimalThread: JSONValue = .object([
        "cliVersion": .string("codexkit"),
        "createdAt": .int(0),
        "cwd": .string("/"),
        "ephemeral": .bool(true),
        "id": .string("thr_generic_default"),
        "modelProvider": .string("openai"),
        "preview": .string(""),
        "sessionId": .string("thr_generic_default"),
        "source": .string("appServer"),
        "status": .object(["type": .string("notLoaded")]),
        "turns": .array([]),
        "updatedAt": .int(0),
    ])
    private static let minimalPluginDetail: JSONValue = .object([
        "apps": .array([]),
        "hooks": .array([]),
        "marketplaceName": .string(""),
        "mcpServers": .array([]),
        "skills": .array([]),
        "summary": .object([
            "authPolicy": .string("ON_USE"),
            "enabled": .bool(false),
            "id": .string(""),
            "installPolicy": .string("NOT_AVAILABLE"),
            "installed": .bool(false),
            "name": .string(""),
            "source": .object(["type": .string("local"), "path": .string("/")]),
        ]),
    ])
    private static let remoteControlStatus: JSONValue = .object([
        "status": .string("disabled"),
        "serverName": .string(""),
        "installationId": .string(""),
        "environmentId": .null,
    ])
    private static let minimalConversationSummary: JSONValue = .object([
        "conversationId": .string("thr_generic_default"),
        "path": .string("/"),
        "preview": .string(""),
        "timestamp": .null,
        "updatedAt": .null,
        "modelProvider": .string("openai"),
        "cwd": .string("/"),
        "cliVersion": .string("codexkit"),
        "source": .string("mcp"),
        "gitInfo": .null,
    ])
    public static let explicitDefaultMethods: Set<String> = [
        "plugin/list", "plugin/installed", "plugin/share/list",
        "marketplace/upgrade", "fuzzyFileSearch", "hooks/list",
        "thread/turns/list", "thread/turns/items/list", "thread/loaded/list",
        "thread/archive", "thread/metadata/update",
        "thread/approveGuardianDeniedAction",
        "thread/backgroundTerminals/clean", "thread/inject_items",
        "thread/compact/start", "thread/shellCommand", "thread/unarchive",
        "thread/unsubscribe", "thread/increment_elicitation",
        "thread/decrement_elicitation", "thread/name/set", "skills/list",
        "skills/config/write", "plugin/install", "plugin/uninstall",
        "plugin/share/save", "plugin/share/updateTargets",
        "plugin/share/checkout", "plugin/share/delete", "marketplace/add",
        "marketplace/remove", "plugin/read", "plugin/skill/read",
        "fs/readFile", "fs/readDirectory", "fs/getMetadata", "fs/writeFile",
        "fs/createDirectory", "fs/remove", "fs/copy", "fs/watch",
        "fs/unwatch", "thread/realtime/start", "thread/realtime/appendAudio",
        "thread/realtime/appendText", "thread/realtime/stop",
        "thread/realtime/listVoices", "windowsSandbox/setupStart",
        "windowsSandbox/readiness", "experimentalFeature/enablement/set",
        "remoteControl/enable", "remoteControl/disable",
        "remoteControl/status/read", "environment/add",
        "mock/experimentalMethod", "config/mcpServer/reload",
        "mcpServer/oauth/login", "mcpServer/resource/read",
        "mcpServer/tool/call", "account/login/start",
        "account/login/cancel", "account/logout",
        "account/sendAddCreditsNudgeEmail", "feedback/upload",
        "command/exec", "command/exec/write", "command/exec/terminate",
        "command/exec/resize", "process/writeStdin", "process/kill",
        "process/resizePty", "process/spawn", "config/read",
        "externalAgentConfig/detect", "externalAgentConfig/import",
        "config/value/write", "config/batchWrite",
        "configRequirements/read", "getConversationSummary",
        "gitDiffToRemote", "getAuthStatus", "fuzzyFileSearch/sessionStart",
        "fuzzyFileSearch/sessionUpdate", "fuzzyFileSearch/sessionStop",
    ]

    public static func hasExplicitDefault(for method: String) -> Bool {
        explicitDefaultMethods.contains(method)
    }

    public static func defaultResult(for method: String) -> JSONValue {
        precondition(hasExplicitDefault(for: method),
                     "Generic default response requires an explicit policy for \(method)")
        switch method {
        // ---- list-style (paginated) ----
        case "fuzzyFileSearch":
            return .object(["files": .array([])])
        case "plugin/list":
            return .object(["marketplaces": .array([]),
                            "marketplaceLoadErrors": .array([]),
                            "featuredPluginIds": .array([])])
        case "plugin/installed":
            return .object(["marketplaces": .array([]),
                            "marketplaceLoadErrors": .array([])])
        case "plugin/share/list":
            return .object(["data": .array([])])
        case "marketplace/upgrade":
            return .object(["selectedMarketplaces": .array([]),
                            "upgradedRoots": .array([]),
                            "errors": .array([])])
        case "hooks/list":
            return .object(["data": .array([])])
        case "thread/turns/list", "thread/turns/items/list":
            return emptyDataCursorBackwards
        case "thread/loaded/list":
            return emptyDataCursor

        // ---- thread mutations / acks ----
        case "thread/archive",
             "thread/approveGuardianDeniedAction",
             "thread/backgroundTerminals/clean", "thread/inject_items",
             "thread/compact/start", "thread/shellCommand":
            return empty
        case "thread/metadata/update":
            return .object(["thread": minimalThread])
        case "thread/unarchive":
            return .object(["thread": minimalThread])
        case "thread/unsubscribe":
            return .object(["status": .string("unsubscribed")])
        case "thread/increment_elicitation", "thread/decrement_elicitation":
            return .object(["count": .int(0), "paused": .bool(false)])
        case "thread/name/set":
            return empty

        // ---- skills / plugins / marketplace ----
        case "skills/list":
            return .object(["data": .array([])])
        case "skills/config/write":
            return .object(["effectiveEnabled": .bool(false)])
        case "plugin/install":
            return .object(["authPolicy": .string("ON_USE"), "appsNeedingAuth": .array([])])
        case "plugin/uninstall", "plugin/share/delete":
            return empty
        case "plugin/share/save":
            return .object(["shareUrl": .string(""), "remotePluginId": .string("")])
        case "plugin/share/updateTargets":
            return .object(["discoverability": .string("PRIVATE"), "principals": .array([])])
        case "plugin/share/checkout":
            return .object(["remotePluginId": .string(""),
                            "pluginId": .string(""),
                            "pluginName": .string(""),
                            "pluginPath": .string(""),
                            "marketplaceName": .string(""),
                            "marketplacePath": .string(""),
                            "remoteVersion": .null])
        case "marketplace/add":
            return .object(["marketplaceName": .string(""),
                            "installedRoot": .string(""),
                            "alreadyAdded": .bool(false)])
        case "marketplace/remove":
            return .object(["marketplaceName": .string(""),
                            "installedRoot": .string("")])
        case "plugin/read":
            return .object(["plugin": minimalPluginDetail])
        case "plugin/skill/read":
            return .object(["contents": .string("")])

        // ---- fs ----
        case "fs/readFile":
            return .object(["dataBase64": .string("")])
        case "fs/readDirectory":
            return .object(["entries": .array([])])
        case "fs/getMetadata":
            return .object(["isDirectory": .bool(false),
                            "isFile": .bool(false),
                            "isSymlink": .bool(false),
                            "createdAtMs": .int(0),
                            "modifiedAtMs": .int(0)])
        case "fs/watch":
            return .object(["path": .string("")])
        case "fs/writeFile", "fs/createDirectory", "fs/remove",
             "fs/copy", "fs/unwatch":
            return empty

        // ---- realtime / windows sandbox ----
        case "thread/realtime/start", "thread/realtime/appendAudio",
             "thread/realtime/appendText", "thread/realtime/stop":
            return empty
        case "thread/realtime/listVoices":
            return .object(["voices": .array([])])
        case "windowsSandbox/setupStart":
            return .object(["started": .bool(false)])
        case "windowsSandbox/readiness":
            return .object(["status": .string("notConfigured")])

        // ---- experimental features / remote control / collab ----
        case "experimentalFeature/enablement/set":
            return .object(["enablement": .object([:])])
        case "remoteControl/enable", "remoteControl/disable",
             "remoteControl/status/read":
            return remoteControlStatus
        case "environment/add":
            return empty
        case "mock/experimentalMethod":
            return .object(["echoed": .null])

        // ---- mcp ----
        case "config/mcpServer/reload":
            return empty
        case "mcpServer/oauth/login":
            return .object(["authorizationUrl": .string("")])
        case "mcpServer/resource/read":
            return .object(["contents": .array([])])
        case "mcpServer/tool/call":
            return .object(["content": .array([]),
                            "structuredContent": .null,
                            "isError": .bool(false),
                            "_meta": .null])

        // ---- account ----
        case "account/login/start":
            return .object(["type": .string("apiKey")])
        case "account/login/cancel":
            return .object(["status": .string("notFound")])
        case "account/logout":
            return empty
        case "account/sendAddCreditsNudgeEmail":
            return .object(["status": .string("sent")])
        case "feedback/upload":
            return .object(["threadId": .string("")])

        // ---- command / process exec ----
        case "command/exec":
            return .object(["exitCode": .int(0), "stdout": .string(""), "stderr": .string("")])
        case "command/exec/write", "command/exec/terminate",
             "command/exec/resize", "process/writeStdin",
             "process/kill", "process/resizePty", "process/spawn":
            return empty

        // ---- config ----
        case "config/read":
            return .object(["config": .object([:]),
                            "origins": .object([:]),
                            "layers": .null])
        case "externalAgentConfig/detect":
            return .object(["items": .array([])])
        case "externalAgentConfig/import":
            return empty
        case "config/value/write", "config/batchWrite":
            return .object(["status": .string("ok"), "version": .string("1"),
                            "filePath": .string(""), "overriddenMetadata": .null])
        case "configRequirements/read":
            return .object(["requirements": .null])

        // ---- deprecated v1 ----
        case "getConversationSummary":
            return .object(["summary": minimalConversationSummary])
        case "gitDiffToRemote":
            return .object(["sha": .string(""), "diff": .string("")])
        case "getAuthStatus":
            return .object(["authMethod": .null,
                            "authToken": .null,
                            "requiresOpenaiAuth": .null])
        case "fuzzyFileSearch/sessionStart",
             "fuzzyFileSearch/sessionUpdate",
             "fuzzyFileSearch/sessionStop":
            return empty

        default:
            return empty
        }
    }
}
