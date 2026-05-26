import Foundation

/// OAuth 2.0 Token Exchange (RFC 8693) used to mint an `OPENAI_API_KEY` from
/// a freshly-issued ChatGPT id_token. Mirrors upstream `obtain_api_key`
/// (codex-rs/login/src/server.rs:1120). After the user completes the ChatGPT
/// OAuth flow, the issuer accepts the id_token as a subject token and returns
/// a long-lived API key in the `access_token` field of the response.
///
/// The exchange is best-effort by contract: callers must treat failure as
/// non-fatal so a ChatGPT login can still succeed when the issuer rejects
/// token exchange (e.g. for a plan tier without API access).
public protocol APIKeyExchanger: Sendable {
    /// Exchange a ChatGPT id_token for an OpenAI API key. Returns the minted
    /// key on success, or throws `AuthError` on transport/server errors.
    func exchangeForAPIKey(idToken: String, cfg: OAuthConfig) async throws -> String
}

/// `@unchecked Sendable` Process box (matches the curl exchange pattern).
private final class APIKeyExchangeProcBox: @unchecked Sendable { let p = Process() }

/// Default curl-based implementation. Form body matches upstream
/// `obtain_api_key`:
///   - grant_type=urn:ietf:params:oauth:grant-type:token-exchange
///   - client_id=<cfg.clientId>
///   - requested_token=openai-api-key
///   - subject_token=<idToken>
///   - subject_token_type=urn:ietf:params:oauth:token-type:id_token
public struct CurlAPIKeyExchanger: APIKeyExchanger {
    public init() {}

    public func exchangeForAPIKey(idToken: String,
                                  cfg: OAuthConfig) async throws -> String {
        guard !idToken.isEmpty else {
            throw AuthError.malformed("token exchange: empty id_token")
        }
        let form = APIKeyExchangeRequest.formFields(idToken: idToken, cfg: cfg)
        let body = form.map { "\(percent($0.0))=\(percent($0.1))" }
            .joined(separator: "&")

        let box = APIKeyExchangeProcBox()
        let p = box.p
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["curl", "-sS", "-X", "POST", cfg.tokenEndpoint,
                       "-H", "Content-Type: application/x-www-form-urlencoded",
                       "-H", "Accept: application/json",
                       "-w", "\n%{http_code}",
                       "--data-binary", "@-"]
        let inPipe = Pipe(); let outPipe = Pipe(); let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() }
        catch { throw AuthError.transport("spawn curl: \(error)") }
        inPipe.fileHandleForWriting.write(Data(body.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let e = errPipe.fileHandleForReading.readDataToEndOfFile()
            throw AuthError.transport("curl exit \(p.terminationStatus): "
                + String(decoding: e.prefix(300), as: UTF8.self))
        }
        let raw = String(decoding: out, as: UTF8.self)
        let parts = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let statusText = parts.last, let status = Int(statusText) else {
            throw AuthError.malformed("token exchange: missing HTTP status")
        }
        let bodyText = parts.dropLast().joined(separator: "\n")
        if !(200..<300).contains(status) {
            throw AuthError.server("api key exchange failed with status \(status)")
        }
        guard let data = bodyText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            throw AuthError.malformed("non-JSON token exchange response")
        }
        guard let access = obj["access_token"] as? String, !access.isEmpty else {
            throw AuthError.malformed("token exchange: missing access_token")
        }
        return access
    }

    /// RFC 3986 unreserved set — mirrors upstream `urlencoding::encode`.
    private func percent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Helper exposed for testing the request shape without hitting the network.
/// Returns the form-body fields in the order upstream emits them so tests can
/// assert byte-for-byte parity.
public enum APIKeyExchangeRequest {
    public static func formFields(idToken: String,
                                  cfg: OAuthConfig) -> [(String, String)] {
        [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("client_id", cfg.clientId),
            ("requested_token", "openai-api-key"),
            ("subject_token", idToken),
            ("subject_token_type", "urn:ietf:params:oauth:token-type:id_token"),
        ]
    }
}
