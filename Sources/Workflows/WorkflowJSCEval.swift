import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Small synchronous JavaScriptCore helpers used by the meta parser and the
/// script compiler. These spin up throwaway contexts and never run untrusted
/// async work, so they're safe to call on any thread.
public enum WorkflowJSCEval {

    /// Evaluate a pure object literal (the `meta` block) and return it as a
    /// `[String: Any]`. Returns nil if JSC is unavailable or the literal is not
    /// a plain object.
    public static func objectLiteral(_ literal: String) -> [String: Any]? {
        #if canImport(JavaScriptCore)
        guard let ctx = JSContext() else { return nil }
        // Wrap in parens so `{...}` is parsed as an expression, not a block.
        let value = ctx.evaluateScript("(\(literal))")
        if ctx.exception != nil { return nil }
        guard let value, value.isObject else { return nil }
        return value.toDictionary() as? [String: Any]
        #else
        return nil
        #endif
    }

    /// Return a SyntaxError message if `body` has a JS syntax error, else nil.
    /// We evaluate the body wrapped in an UNCALLED async function expression:
    /// no execution / side effects, but JSC's pre-parser validates the whole
    /// function (bracket matching, tokens) and reports SyntaxErrors.
    public static func syntaxError(forBody body: String) -> String? {
        #if canImport(JavaScriptCore)
        guard let ctx = JSContext() else { return "failed to create JSContext" }
        _ = ctx.evaluateScript("(async function(){\n\(body)\n})")
        guard let exc = ctx.exception else { return nil }
        let name = exc.objectForKeyedSubscript("name")?.toString() ?? ""
        let text = exc.toString() ?? "syntax error"
        if name == "SyntaxError" || text.contains("SyntaxError") {
            return text
        }
        // A non-syntax exception while merely *defining* the function is
        // unexpected, but treat it as a syntax-level failure too.
        return nil
        #else
        return "workflow scripts require the JavaScriptCore runtime (macOS build)"
        #endif
    }
}
