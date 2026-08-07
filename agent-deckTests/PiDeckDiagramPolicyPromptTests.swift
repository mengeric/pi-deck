import XCTest
@testable import agent_deck

/// Product diagram policy must ship as always-on append text, not only a user skill.
final class PiDeckDiagramPolicyPromptTests: XCTestCase {
    /// Ensures the append body bans toy trees / toy Mermaid and names the product skill.
    func testAppendPromptContainsHardBansAndProductMarkers() {
        let text = PiDeckDiagramPolicyPrompt.appendSystemPromptText
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(text.contains("Hard bans"))
        XCTAssertTrue(text.contains("Toy Mermaid") || text.contains("toy"))
        XCTAssertTrue(text.contains("mermaid") || text.contains("Mermaid"))
        XCTAssertTrue(text.contains("→") || text.contains("Fake diagrams"))
        XCTAssertEqual(PiDeckDiagramPolicyPrompt.bundledSkillName, "professional-mermaid")
    }

    /// Helper (non-chat) launches must not receive chat diagram chrome.
    func testShouldAppendSkipsHelperSessions() {
        XCTAssertTrue(PiDeckDiagramPolicyPrompt.shouldAppend(isHelperSession: false))
        XCTAssertFalse(PiDeckDiagramPolicyPrompt.shouldAppend(isHelperSession: true))
    }
}
