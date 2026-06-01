import Foundation
import ProtocolModel
import WireProtocol

/// Upstream parity: the elicitation policy applied BEFORE an
/// `elicitation/create` server request is surfaced to the frontend
/// (`codex-rs/codex-mcp/src/elicitation.rs` `ElicitationRequestManager::make_sender`).
///
/// The policy short-circuits in three ways, in order:
///   1. `autoDeny` set        → reply `{"action":"decline"}` (no prompt).
///   2. auto-approved + the elicitation can be auto-accepted (a *form*
///      elicitation whose `requestedSchema.properties` is empty, i.e. a
///      bare confirm/approval) → reply `{"action":"accept","content":{}}`.
///   3. rejected-by-policy     → reply `{"action":"decline"}`.
/// Only when none of these fire is the request handed to the frontend.
///
/// Mirrors `elicitation_is_rejected_by_policy` (Never → always reject;
/// Granular → reject unless `allows_mcp_elicitations`) and
/// `can_auto_accept_elicitation` (Form with empty properties → yes; Url → no)
/// and `mcp_permission_prompt_is_auto_approved` (only auto-approves under
/// `Never` + a full-write/Disabled permission profile).
public enum McpElicitationPolicy: Sendable {
    /// The resolved policy decision for an incoming elicitation.
    public enum Decision: Sendable, Equatable {
        /// Auto-decline without prompting (`{"action":"decline"}`).
        case decline
        /// Auto-accept without prompting (`{"action":"accept","content":{}}`).
        case accept
        /// No short-circuit applied; surface the request to the frontend.
        case prompt
    }

    /// Inputs the policy needs. `autoApproved` mirrors
    /// `mcp_permission_prompt_is_auto_approved(...)` which the caller computes
    /// from the approval policy + permission profile; in the host that is only
    /// ever `true` under `Never` + a full-disk-write / Disabled / External
    /// profile.
    public static func decide(approvalPolicy: ApprovalPolicy,
                              autoDeny: Bool,
                              autoApproved: Bool,
                              params: JSONValue) -> Decision {
        // 1. Hard auto-deny toggle wins unconditionally.
        if autoDeny { return .decline }
        // 2. Auto-accept schemaless confirm/approval form elicitations when the
        //    permission prompt is auto-approved.
        if autoApproved && canAutoAccept(params: params) {
            return .accept
        }
        // 3. Reject-by-policy (Never always; Granular when MCP elicitations off).
        if isRejectedByPolicy(approvalPolicy) {
            return .decline
        }
        // 4. Otherwise surface to the frontend.
        return .prompt
    }

    /// `elicitation_is_rejected_by_policy` (elicitation.rs:234-242):
    /// `Never` → true; `Granular` → `!allows_mcp_elicitations`; otherwise false.
    public static func isRejectedByPolicy(_ policy: ApprovalPolicy) -> Bool {
        switch policy {
        case .never: return true
        case .onFailure, .onRequest, .unlessTrusted: return false
        case .granular(let cfg): return !cfg.allowsMcpElicitations
        }
    }

    /// `can_auto_accept_elicitation` (elicitation.rs:246-256): a *form*
    /// elicitation whose `requestedSchema.properties` is empty (or absent) can
    /// be auto-accepted; a *url* elicitation never can.
    ///
    /// Upstream `CreateElicitationRequestParams` is an `#[serde(tag = "mode")]`
    /// tagged union (rmcp-0.15.0/src/model.rs:2004-2031) with variants
    /// `"form"` / `"url"`; when `mode` is absent it defaults to the form
    /// variant (`CreateElicitationRequestParamDeserializeHelper`). We therefore
    /// classify off the `mode` discriminator first:
    ///   * `mode == "url"` → url elicitation → never auto-accept.
    ///   * `mode == "form"` or absent → form → auto-accept iff
    ///     `requestedSchema.properties` is empty.
    /// The legacy `url`-field presence check is kept only as a fallback for the
    /// missing-mode case, so a spec-conformant url payload (which carries `url`
    /// but, in malformed inputs, may omit `mode`) is still classified as url.
    public static func canAutoAccept(params: JSONValue) -> Bool {
        // 1. Authoritative `mode` discriminator.
        if case .string(let mode)? = params["mode"] {
            switch mode {
            case "url":
                // URL elicitations are never auto-accepted, regardless of any
                // (absent) `url` field — the tag is authoritative.
                return false
            case "form":
                return formPropertiesEmpty(params)
            default:
                // Unknown tag: be conservative and surface to the frontend.
                return false
            }
        }
        // 2. Missing `mode` → form is the serde default, but tolerate a stray
        //    `url` field as the url variant for spec-conformant payloads that
        //    omit the tag.
        if case .string(let u)? = params["url"], !u.isEmpty { return false }
        return formPropertiesEmpty(params)
    }

    /// Form auto-accept predicate: true iff `requestedSchema.properties` is an
    /// empty object (or the schema/properties are absent).
    private static func formPropertiesEmpty(_ params: JSONValue) -> Bool {
        guard let schema = params["requestedSchema"] else {
            // No schema at all → treated as a form with no properties.
            return true
        }
        guard let props = schema["properties"] else { return true }
        if case .object(let o) = props { return o.isEmpty }
        // A non-object `properties` value is malformed; be conservative and
        // do NOT auto-accept (surface to the frontend instead).
        return false
    }

    /// Transport-level `_meta` key carrying the progress token. Mirrors
    /// `MCP_PROGRESS_TOKEN_META_KEY` (rmcp-client/src/elicitation_client_service.rs:24).
    public static let progressTokenMetaKey = "progressToken"

    /// Classify the surfaced elicitation `mode` ("form"/"url") off the
    /// authoritative `mode` discriminator first, matching the rmcp tagged union
    /// (codex-mcp/src/elicitation.rs:174-202). Only when `mode` is absent do we
    /// fall back to the legacy requestedSchema-presence heuristic (a payload
    /// with no `requestedSchema` is treated as a url elicitation). This keeps the
    /// surfaced event label aligned with `canAutoAccept`'s own classification.
    public static func classifyMode(params: JSONValue) -> String {
        if case .string(let m)? = params["mode"] { return m }
        return params["requestedSchema"] == nil ? "url" : "form"
    }

    /// Strip the transport-level `progressToken` from an elicitation `_meta`
    /// before surfacing it to the frontend, mirroring upstream
    /// `restore_context_meta` (elicitation_client_service.rs:110-122). Returns
    /// `.null` when no `_meta` is present or nothing remains after scrubbing.
    public static func scrubMeta(_ meta: JSONValue?) -> JSONValue {
        guard case .object(var obj)? = meta else { return meta ?? .null }
        obj.removeValue(forKey: progressTokenMetaKey)
        if obj.isEmpty { return .null }
        return .object(obj)
    }
}
