import XCTest
import ProtocolModel
@testable import HarnessCore

/// The "workflow"/"workflows" keyword opt-in detection lives on SessionEngine.
final class WorkflowTriggerTests: XCTestCase {
    private func fires(_ text: String) -> Bool {
        SessionEngine.workflowTriggerFires(forInput: [TurnInput(text: text)])
    }

    func testFiresOnWholeWord() {
        XCTAssertTrue(fires("please run a workflow for this"))
        XCTAssertTrue(fires("use workflows to fan out"))
        XCTAssertTrue(fires("/workflow deep-research climate"))
        XCTAssertTrue(fires("WORKFLOW now"))
    }

    func testDoesNotFireOnSubstring() {
        XCTAssertFalse(fires("this is workflowy and workflowish"))
        XCTAssertFalse(fires("subworkflows are different"))   // not bounded by start
        XCTAssertFalse(fires("just a normal request"))
    }
}
