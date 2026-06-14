import Foundation

/// Pure mode classification (§6). Precedence: explicit `--mode` wins; thesis signal
/// words beat question shape (so "is it true that X" is a thesis, not a question);
/// question shape (`what/why/how…` or a trailing `?`) → question; else topic.
public enum ResearchModeDetector {
    static let thesisSignals = [
        "prove that", "prove the", "is it true", "is it the case", "verify that", "verify the",
        "verify ", "test the claim", "test the hypothesis", "test whether", "hypothesis",
        "debunk", "fact check", "fact-check", "disprove", "confirm that", "confirm whether",
    ]
    static let questionStarters = [
        "what ", "what's", "why ", "how ", "when ", "where ", "who ", "which ", "whose ",
        "does ", "do ", "is ", "are ", "can ", "could ", "should ", "would ", "will ", "did ",
    ]

    public static func detect(_ input: String, forced: ResearchMode? = nil) -> ResearchMode {
        if let forced { return forced }
        let l = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if thesisSignals.contains(where: { l.contains($0) }) { return .thesis }
        if input.contains("?") || questionStarters.contains(where: { l.hasPrefix($0) }) { return .question }
        return .topic
    }
}
