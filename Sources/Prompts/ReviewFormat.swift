import Foundation

/// Byte-faithful port of Codex `core/src/review_format.rs`.
///
/// This module is UI-agnostic: it returns plain strings that higher layers
/// (e.g. a frontend) may style. It reproduces the exact header strings, the
/// per-item `- {title} — {path}:{start}-{end}` line format, the 2-space body
/// indentation, the optional `[x]`/`[ ]` selection markers, and the
/// `REVIEW_FALLBACK_MESSAGE`.

// MARK: - Structured review result types (protocol/src/protocol.rs:2996-3038)

/// Inclusive line range in a file associated with a finding (`ReviewLineRange`).
public struct ReviewLineRange: Sendable, Equatable, Codable {
    public var start: UInt32
    public var end: UInt32
    public init(start: UInt32, end: UInt32) {
        self.start = start; self.end = end
    }
}

/// Location of the code related to a review finding (`ReviewCodeLocation`).
public struct ReviewCodeLocation: Sendable, Equatable, Codable {
    public var absoluteFilePath: String
    public var lineRange: ReviewLineRange
    public init(absoluteFilePath: String, lineRange: ReviewLineRange) {
        self.absoluteFilePath = absoluteFilePath; self.lineRange = lineRange
    }
    enum CodingKeys: String, CodingKey {
        case absoluteFilePath = "absolute_file_path"
        case lineRange = "line_range"
    }
}

/// A single review finding describing an observed issue (`ReviewFinding`).
public struct ReviewFinding: Sendable, Equatable, Codable {
    public var title: String
    public var body: String
    public var confidenceScore: Float
    public var priority: Int32
    public var codeLocation: ReviewCodeLocation
    public init(title: String, body: String, confidenceScore: Float = 0,
                priority: Int32 = 0, codeLocation: ReviewCodeLocation) {
        self.title = title; self.body = body
        self.confidenceScore = confidenceScore; self.priority = priority
        self.codeLocation = codeLocation
    }
    enum CodingKeys: String, CodingKey {
        case title, body, priority
        case confidenceScore = "confidence_score"
        case codeLocation = "code_location"
    }
}

/// Structured review result produced by a child review session
/// (`ReviewOutputEvent`).
public struct ReviewOutputEvent: Sendable, Equatable, Codable {
    public var findings: [ReviewFinding]
    public var overallCorrectness: String
    public var overallExplanation: String
    public var overallConfidenceScore: Float
    public init(findings: [ReviewFinding] = [], overallCorrectness: String = "",
                overallExplanation: String = "", overallConfidenceScore: Float = 0) {
        self.findings = findings; self.overallCorrectness = overallCorrectness
        self.overallExplanation = overallExplanation
        self.overallConfidenceScore = overallConfidenceScore
    }
    enum CodingKeys: String, CodingKey {
        case findings
        case overallCorrectness = "overall_correctness"
        case overallExplanation = "overall_explanation"
        case overallConfidenceScore = "overall_confidence_score"
    }
}

// MARK: - Rendering (review_format.rs:7-82)

public enum ReviewFormat {
    /// `review_format.rs:14`.
    public static let reviewFallbackMessage = "Reviewer failed to output a response."

    /// Faithful port of `core/src/tasks/review.rs::parse_review_output_event`
    /// (review.rs:194-210): parse a `ReviewOutputEvent` from a text blob
    /// returned by the reviewer model. If the whole text is valid JSON matching
    /// the struct, deserialize it; otherwise extract the first `{`…last `}`
    /// substring and try again; if parsing still fails, return a structured
    /// fallback carrying the plain text in `overallExplanation`.
    ///
    /// NOTE: like upstream's `ReviewOutputEvent` (no `#[serde(default)]`),
    /// strict decode requires `findings`, `overall_correctness`,
    /// `overall_explanation`, and `overall_confidence_score` to all be present;
    /// a partial object falls through to the plain-text fallback.
    public static func parseReviewOutputEvent(_ text: String) -> ReviewOutputEvent {
        let dec = JSONDecoder()
        if let data = text.data(using: .utf8),
           let ev = try? dec.decode(ReviewOutputEvent.self, from: data) {
            return ev
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end {
            let slice = String(text[start...end])
            if let data = slice.data(using: .utf8),
               let ev = try? dec.decode(ReviewOutputEvent.self, from: data) {
                return ev
            }
        }
        return ReviewOutputEvent(overallExplanation: text)
    }

    /// `format_location` (review_format.rs:7-12): `{path}:{start}-{end}`.
    static func formatLocation(_ item: ReviewFinding) -> String {
        let loc = item.codeLocation
        return "\(loc.absoluteFilePath):\(loc.lineRange.start)-\(loc.lineRange.end)"
    }

    /// Format a full review findings block as plain text lines
    /// (`format_review_findings_block`, review_format.rs:23-58).
    ///
    /// - When `selection` is non-nil, each item line includes a checkbox
    ///   marker: `[x]` for selected items and `[ ]` for unselected. Indices
    ///   beyond the array default to selected.
    /// - When `selection` is nil, the marker is omitted and a simple bullet is
    ///   rendered (`- {title} — {location}`).
    public static func formatReviewFindingsBlock(
        _ findings: [ReviewFinding],
        selection: [Bool]? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("")

        // Header
        if findings.count > 1 {
            lines.append("Full review comments:")
        } else {
            lines.append("Review comment:")
        }

        for (idx, item) in findings.enumerated() {
            lines.append("")

            let title = item.title
            let location = formatLocation(item)

            if let flags = selection {
                // Default to selected if index is out of bounds.
                let checked = idx < flags.count ? flags[idx] : true
                let marker = checked ? "[x]" : "[ ]"
                lines.append("- \(marker) \(title) — \(location)")
            } else {
                lines.append("- \(title) — \(location)")
            }

            for bodyLine in rustLines(item.body) {
                lines.append("  \(bodyLine)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Render a human-readable review summary suitable for a user-facing
    /// message (`render_review_output_text`, review_format.rs:64-82).
    ///
    /// Returns the explanation, the formatted findings block, or both
    /// separated by a blank line. If neither is present, emits the fallback.
    public static func renderReviewOutputText(_ output: ReviewOutputEvent) -> String {
        var sections: [String] = []
        let explanation = output.overallExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explanation.isEmpty {
            sections.append(explanation)
        }
        if !output.findings.isEmpty {
            let findings = formatReviewFindingsBlock(output.findings, selection: nil)
            let trimmed = findings.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sections.append(trimmed)
            }
        }
        if sections.isEmpty {
            return reviewFallbackMessage
        }
        return sections.joined(separator: "\n\n")
    }
}
