import Foundation

/// The JavaScript fragments evaluated inside each workflow's JSContext, plus
/// the `meta` parser and script compiler. Faithful to the Claude feature's
/// determinism shim (`F03`) and primitive surface, adapted to a JSC host that
/// uses two native bridges:
///   * `__wf_sync(verb, argsJSON) -> string`   — phase/log/budget (synchronous)
///   * `__wf_async(verb, argsJSON) -> Promise`  — agent/workflow (real JS Promise)
public enum WorkflowJS {

    /// Determinism shim — `Date.now()`, `Math.random()`, argless `new Date()`
    /// and bare `Date()` all throw (they break resume); `new Date(2020,0,1)`
    /// still works. Verbatim port of `F03` with the GPT-neutral messages.
    public static let determinismShim = #"""
    (() => {
      const NOW_ERR = "Date.now() / new Date() are unavailable in workflow scripts (they break resume). Stamp results after the workflow returns, or pass timestamps via args.";
      const RANDOM_ERR = "Math.random() is unavailable in workflow scripts (it breaks resume). For N independent samples, include the index in the agent label or prompt.";
      Math.random = function random(){ throw new Error(RANDOM_ERR); };
      const RealDate = Date;
      RealDate.now = function now(){ throw new Error(NOW_ERR); };
      function ShimDate(...a){
        if (!new.target) throw new Error(NOW_ERR);
        if (a.length === 0) throw new Error(NOW_ERR);
        return Reflect.construct(RealDate, a, new.target);
      }
      ShimDate.now = RealDate.now;
      ShimDate.parse = RealDate.parse;
      ShimDate.UTC = RealDate.UTC;
      ShimDate.prototype = RealDate.prototype;
      RealDate.prototype.constructor = ShimDate;
      Object.freeze(RealDate);
      globalThis.Date = ShimDate;
    })();
    """#

    /// Reduced hardening shim — closes the obvious escape hatches. Full SES
    /// intrinsic-freezing is unnecessary in a single-shot JSC context with no
    /// `require`/`process`/`fs`/network surface (see PORT_DESIGN.md §3.5).
    public static let hardeningShim = #"""
    (() => {
      try { delete globalThis.ShadowRealm; } catch (_) {}
      try { delete globalThis.WebAssembly; } catch (_) {}
    })();
    """#

    /// The primitive prelude. Defines `agent/parallel/pipeline/phase/log/budget`
    /// (+ `workflow` when nesting is allowed) over the two native bridges, with
    /// the exact Claude semantics, then null-proto-freezes each primitive so
    /// scripts can't climb `agent.constructor` to the Function constructor.
    ///
    /// `allowNested` is false inside a nested workflow (child `workflow()`
    /// rejects, child `phase()` is a no-op — handled host-side via `__wf_sync`).
    public static func prelude(allowNested: Bool) -> String {
        let workflowFn = allowNested
            ? "globalThis.workflow = function(nameOrRef, a){ return __wf_async('workflow', JSON.stringify({ ref: nameOrRef, args: a === undefined ? null : a })); };"
            : "globalThis.workflow = function(){ throw new Error('workflow() cannot be nested more than one level deep'); };"
        return #"""
        (() => {
          function syncCall(verb, a){
            var r = __wf_sync(verb, JSON.stringify(a === undefined ? null : a));
            try { return JSON.parse(r); } catch (e) { return r; }
          }

          globalThis.agent = function(prompt, opts){
            return __wf_async('agent', JSON.stringify({ prompt: prompt, opts: opts || {} }));
          };

          // parallel: barrier via allSettled; rejected slots → null. The call
          // itself never rejects.
          globalThis.parallel = function(thunks){
            if (!Array.isArray(thunks)) throw new TypeError('parallel() expects an array of functions');
            var ps = thunks.map(function(t){
              if (typeof t !== 'function') throw new TypeError('parallel() expects an array of functions (thunks), not promises. Wrap each call: () => agent(...)');
              return Promise.resolve().then(t);
            });
            return Promise.allSettled(ps).then(function(rs){
              return rs.map(function(r){ return r.status === 'fulfilled' ? r.value : null; });
            });
          };

          // pipeline: per-item independent stage chains, NO barrier between
          // stages. A stage that throws drops the item to null; a stage that
          // returns null/undefined short-circuits the item to null.
          globalThis.pipeline = function(items, ...stages){
            if (!Array.isArray(items)) throw new TypeError('pipeline() expects an array of items as the first argument');
            return Promise.all(items.map(async function(item, index){
              var v = item;
              for (var s = 0; s < stages.length; s++){
                try { v = await stages[s](v, item, index); }
                catch (e) { return null; }
                if (v === null || v === undefined) return null;
              }
              return v;
            }));
          };

          globalThis.phase = function(title){ return syncCall('phase', { title: String(title) }); };
          globalThis.log   = function(message){ syncCall('log', { message: String(message) }); };

          var __budgetTotalCache;
          globalThis.budget = Object.freeze({
            get total(){
              if (__budgetTotalCache === undefined) __budgetTotalCache = syncCall('budget_total', {});
              return __budgetTotalCache;
            },
            spent: function(){ return syncCall('budget_spent', {}); },
            remaining: function(){ var r = syncCall('budget_remaining', {}); return r === null ? Infinity : r; }
          });

          __WORKFLOW_FN__

          [agent, parallel, pipeline, phase, log, workflow].forEach(function(f){
            try { Object.setPrototypeOf(f, null); } catch (_) {}
            try { delete f.constructor; } catch (_) {}
            try { delete f.prototype; } catch (_) {}
          });
        })();
        """#.replacingOccurrences(of: "__WORKFLOW_FN__", with: workflowFn)
    }
}

// MARK: - meta parser

public enum WorkflowMeta {
    public struct Parsed: Sendable, Equatable {
        public var name: String
        public var description: String
        public var whenToUse: String?
        public var phases: [WorkflowDef.Phase]
        public var title: String?
        public var scriptBody: String
    }

    public enum ParseError: Error, Equatable {
        case noMeta
        case invalidMeta(String)
    }

    /// Parse the leading `export const meta = { ... };` literal out of a
    /// workflow script and return the parsed meta + the remaining body. Faithful
    /// to the external `g0` parser: the meta must be a pure object literal.
    public static func parse(_ script: String) throws -> Parsed {
        guard let exportRange = script.range(of: "export const meta") else {
            throw ParseError.noMeta
        }
        // Find the first `{` after the `=`.
        guard let eq = script.range(of: "=", range: exportRange.upperBound..<script.endIndex),
              let open = script.range(of: "{", range: eq.upperBound..<script.endIndex) else {
            throw ParseError.invalidMeta("malformed `export const meta` declaration")
        }
        // Balance braces (string/comment-naive but adequate for the literal
        // shape we require — pure JSON-ish object literals).
        let chars = Array(script)
        let startIdx = script.distance(from: script.startIndex, to: open.lowerBound)
        var depth = 0
        var endIdx = -1
        var inString: Character? = nil
        var escaped = false
        var i = startIdx
        while i < chars.count {
            let c = chars[i]
            if let q = inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == q { inString = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                inString = c
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { endIdx = i; break }
            }
            i += 1
        }
        guard endIdx >= 0 else { throw ParseError.invalidMeta("unbalanced braces in meta literal") }
        let literal = String(chars[startIdx...endIdx])
        let body = String(chars[(endIdx + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // drop a leading `;` left by `= {...};`
        let cleanBody = body.hasPrefix(";") ? String(body.dropFirst()) : body

        let obj = try evalObjectLiteral(literal)
        guard let name = obj["name"] as? String, !name.isEmpty else {
            throw ParseError.invalidMeta("meta.name is required")
        }
        guard let desc = obj["description"] as? String else {
            throw ParseError.invalidMeta("meta.description is required")
        }
        var phases: [WorkflowDef.Phase] = []
        if let arr = obj["phases"] as? [[String: Any]] {
            for p in arr {
                guard let t = p["title"] as? String else { continue }
                phases.append(.init(title: t, detail: p["detail"] as? String,
                                    model: p["model"] as? String))
            }
        }
        return Parsed(name: name, description: desc,
                      whenToUse: obj["whenToUse"] as? String,
                      phases: phases, title: obj["title"] as? String,
                      scriptBody: cleanBody)
    }

    /// Evaluate a JS object literal into `[String: Any]` using JSONSerialization
    /// after a light JS→JSON normalization (the meta block is required to be a
    /// pure literal, so this is sufficient and avoids spinning up a JSContext).
    static func evalObjectLiteral(_ literal: String) throws -> [String: Any] {
        // Use JavaScriptCore when available for exact JS-literal semantics;
        // otherwise fall back to a JSON-ish reading.
        if let obj = WorkflowJSCEval.objectLiteral(literal) { return obj }
        throw ParseError.invalidMeta("could not evaluate meta object literal")
    }
}

// MARK: - compiler

public enum WorkflowCompiler {
    public enum CompileError: Error, Equatable {
        case syntax(String)
        case tooLarge(Int)
    }

    /// Syntax-check the body and return the IIFE-wrapped source used by the
    /// engine. There is no `vm.Script` in JSC; we syntax-check by parsing the
    /// body in a throwaway context (without running it) and inspecting the
    /// exception.
    public static func compile(scriptBody: String) throws -> String {
        let bytes = scriptBody.utf8.count
        guard bytes <= WF.maxScriptBytes else { throw CompileError.tooLarge(bytes) }
        if let err = WorkflowJSCEval.syntaxError(forBody: scriptBody) {
            throw CompileError.syntax(err)
        }
        return wrap(scriptBody)
    }

    /// The async IIFE the engine evaluates. The result is captured by the
    /// engine's bootstrap (`Promise.resolve(...).then(...)`).
    static func wrap(_ body: String) -> String {
        "(async function(){\n" + body + "\n})()"
    }
}
