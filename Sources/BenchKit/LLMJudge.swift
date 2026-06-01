import Foundation

/// Independent LLM-as-judge using the local **codex CLI** (`codex exec
/// --output-schema`). Mirrors deepswe's *audit* judge: it sees the task, the
/// agent's diff, the verifier result, and the held-out reference solution, then
/// returns a schema-validated verdict. Used to audit our verifier reproduction
/// and as a reported quality dimension — never folded into Pass@1.
public struct LLMJudge: Sendable {
    public let judgeModel: String?     // nil → codex's configured default
    public init(judgeModel: String? = ProcessInfo.processInfo.environment["CODEX_BENCH_JUDGE_MODEL"]) {
        self.judgeModel = judgeModel
    }

    static let schema = """
    {"type":"object","additionalProperties":false,
     "properties":{
       "outcome":{"type":"string","enum":["pass","fail"]},
       "agrees_with_verifier":{"type":"boolean"},
       "failure_mode":{"type":"string","enum":["none","incomplete","regression","wrong_approach","no_change","other"]},
       "rationale":{"type":"string"}},
     "required":["outcome","agrees_with_verifier","failure_mode","rationale"]}
    """

    public func judge(task: TaskSpec, modelPatchPath: String, verifier: VerifierOutcome,
                      log: @escaping @Sendable (String) -> Void) async -> JudgeVerdict? {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("judge-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let schemaURL = scratch.appendingPathComponent("schema.json")
        let outURL = scratch.appendingPathComponent("verdict.json")
        try? Data(Self.schema.utf8).write(to: schemaURL)

        func clip(_ path: String, _ max: Int) -> String {
            let s = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return s.count > max ? String(s.prefix(max)) + "\n…[truncated]…" : s
        }
        let prompt = """
        You are an expert code reviewer auditing an automated SWE benchmark verifier. \
        Decide whether the agent's diff correctly implements the requested behavior, \
        judging ONLY by observable behavior (public APIs/outputs), NOT internal structure \
        and NOT similarity to the reference solution (a correct implementation may look \
        completely different from the reference). \
        IMPORTANT: the deterministic verifier is authoritative and its tests are comprehensive. \
        If the verifier passed (reward=1), treat the implementation as CORRECT (outcome=pass) \
        unless you have concrete evidence the tests themselves are wrong. \
        A diff that adds the feature but breaks unrelated behavior is a FAIL.

        ## Task
        \(task.displayTitle)

        \(task.instruction)

        ## Agent diff (model.patch)
        ```diff
        \(clip(modelPatchPath, 16000))
        ```

        ## Reference solution (held out; the agent never saw this — for your judgment only)
        ```diff
        \(clip(task.solutionPatchPath, 12000))
        ```

        ## Deterministic verifier result
        reward=\(verifier.reward) (base_exit=\(verifier.baseExit.map(String.init) ?? "?"), new_exit=\(verifier.newExit.map(String.init) ?? "?"))

        Respond with ONLY the JSON object required by the output schema. `agrees_with_verifier` \
        must be true iff your `outcome` matches the verifier (pass ⇔ reward==1).
        """

        var args = ["codex", "exec", "--skip-git-repo-check", "-s", "read-only",
                    "--output-schema", schemaURL.path, "--output-last-message", outURL.path]
        if let judgeModel { args += ["-m", judgeModel] }
        let r = await Subprocess.run("/usr/bin/env", args, cwd: scratch.path,
                                     stdin: prompt, timeout: .seconds(300))
        guard let data = try? Data(contentsOf: outURL),
              let obj = try? JSONSerialization.jsonObject(with: extractJSON(data)) as? [String: Any] else {
            log("[\(task.id)] judge produced no parseable verdict (exit \(r.exitCode))")
            return nil
        }
        return JudgeVerdict(
            outcome: obj["outcome"] as? String ?? "fail",
            agreesWithVerifier: obj["agrees_with_verifier"] as? Bool ?? false,
            failureMode: obj["failure_mode"] as? String ?? "other",
            rationale: obj["rationale"] as? String ?? "",
            model: judgeModel ?? "codex-default")
    }

    /// The output-last-message file is the model's final message; with a schema
    /// it is the JSON object, but tolerate a stray code fence just in case.
    private func extractJSON(_ data: Data) -> Data {
        let s = String(decoding: data, as: UTF8.self)
        if let lo = s.firstIndex(of: "{"), let hi = s.lastIndex(of: "}"), lo < hi {
            return Data(s[lo...hi].utf8)
        }
        return data
    }
}
