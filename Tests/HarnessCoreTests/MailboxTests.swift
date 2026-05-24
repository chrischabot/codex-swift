import XCTest
@testable import HarnessCore

final class MailboxTests: XCTestCase {

    func testInterAgentCommunicationCompactJSONKeyOrderAndRoundTrip() {
        let c = InterAgentCommunication(
            author: "/root/a", recipient: "/root/b",
            otherRecipients: ["/root/c"], content: "hi \"there\"\nx",
            triggerTurn: true)
        XCTAssertEqual(c.jsonString(),
            "{\"author\":\"/root/a\",\"recipient\":\"/root/b\",\"other_recipients\":[\"/root/c\"],\"content\":\"hi \\\"there\\\"\\nx\",\"trigger_turn\":true}")
        let parsed = InterAgentCommunication.fromText(c.jsonString())
        XCTAssertEqual(parsed, c)
        // serde(default) other_recipients.
        let p2 = InterAgentCommunication.fromText(
            "{\"author\":\"x\",\"recipient\":\"y\",\"content\":\"z\",\"trigger_turn\":false}")
        XCTAssertEqual(p2?.otherRecipients, [])
    }

    func testToResponseInputItemIsAssistantCommentary() {
        let c = InterAgentCommunication(author: "a", recipient: "b",
                                        content: "m", triggerTurn: false)
        let r = c.toResponseInputItem()
        XCTAssertEqual(r.role, "assistant")
        XCTAssertEqual(r.phase, "commentary")
        XCTAssertEqual(r.text, c.jsonString())
    }

    func testMailboxMonotonicSeqAndDeliveryOrderDrain() async {
        let mb = Mailbox()
        let s1 = await mb.send(InterAgentCommunication(author: "a", recipient: "b",
                                                       content: "1", triggerTurn: false))
        let s2 = await mb.send(InterAgentCommunication(author: "a", recipient: "b",
                                                       content: "2", triggerTurn: true))
        let s3 = await mb.send(InterAgentCommunication(author: "a", recipient: "b",
                                                       content: "3", triggerTurn: false))
        XCTAssertEqual([s1, s2, s3], [1, 2, 3])
        let seq = await mb.currentSeq()
        XCTAssertEqual(seq, 3)
        let pending1 = await mb.hasPending()
        XCTAssertTrue(pending1)
        let trigger1 = await mb.hasPendingTriggerTurn()
        XCTAssertTrue(trigger1)
        let drained = await mb.drain()
        XCTAssertEqual(drained.map { $0.content }, ["1", "2", "3"])
        let pending2 = await mb.hasPending()
        XCTAssertFalse(pending2)
        let trigger2 = await mb.hasPendingTriggerTurn()
        XCTAssertFalse(trigger2)
        // drain is one-shot.
        let drainedAgain = await mb.drain()
        XCTAssertTrue(drainedAgain.isEmpty)
    }

    func testWaitForSeqChangeWakesOnSend() async {
        let mb = Mailbox()
        let waiter = Task { await mb.waitForSeqChange() }
        try? await Task.sleep(for: .milliseconds(20))
        _ = await mb.send(InterAgentCommunication(author: "a", recipient: "b",
                                                  content: "x", triggerTurn: false))
        let seen = await waiter.value
        XCTAssertEqual(seen, 1)
    }
}