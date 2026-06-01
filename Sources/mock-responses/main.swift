import Foundation
import ModelClient
import InfraPrimitives

@main
struct MockResponsesMain {
    static func main() async {
        // Drives the deterministic scenario engine that powers the test
        // harness (plan §TA1). The HTTP/SSE+WS server front-end is a macOS/
        // network completion item; the scenario engine itself is exercised
        // here end-to-end.
        let mock = MockModelClient([
            MockScenario([
                .created,
                .delta(itemId: "m1", "Hello "),
                .delta(itemId: "m1", "world"),
                .agentDone(itemId: "m1", "Hello world"),
                .toolCall(callId: "c1", name: "echo", argumentsJSON: "{\"text\":\"hi\"}"),
                .completeContinue(responseId: "r1", tokens: 7),
            ]),
            .hello("done"),
        ])
        do {
            for round in 1...2 {
                let s = try await mock.stream(
                    Prompt(instructions: "demo", input: [.userText("go")]),
                    ModelSettings(model: "gpt-5.5", threadId: "thr_demo", turnState: "ts1"))
                print("--- round \(round) ---")
                for try await ev in s.events { print(ev) }
            }
            let caps = await mock.capturedRequests()
            print("captured \(caps.count) requests; promptCacheKey=\(caps.first?.promptCacheKey ?? "?")")
        } catch {
            FileHandle.standardError.write(Data("mock-responses error: \(error)\n".utf8))
            exit(1)
        }
    }
}