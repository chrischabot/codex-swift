import Foundation

/// Prompt builders ported from `mem0-rs/crates/mem0-core/src/prompts/mod.rs`.
/// The large verbatim constants live in `Prompts+Constants.swift`
/// (`Mem0PromptConstants`, generated from the Python source).
public enum Mem0Prompts {
    static let pastMessageTruncationLimit = 300

    static func truncateContent(_ text: String, _ limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "..."
    }

    static func formatConversationHistory(_ messages: [(String, String)]) -> String {
        var result = ""
        for (role, content) in messages where !role.isEmpty && !content.isEmpty {
            result += "\(role): \(truncateContent(content, pastMessageTruncationLimit))\n"
        }
        return result
    }

    static func serializeMemories(_ memories: [JSONValue]) -> String {
        JSONValue.array(memories).jsonString(sortedKeys: true)
    }

    static func todayUTC() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Arguments for `generateAdditiveExtractionPrompt`.
    public struct AdditivePromptArgs: Sendable {
        public var summary: String = ""
        public var recentlyExtractedMemories: [JSONValue] = []
        public var existingMemories: [JSONValue] = []
        public var newMessages: String = ""
        public var lastKMessages: [(String, String)] = []
        public var currentDate: String? = nil
        public var observationDate: String? = nil
        public var customInstructions: String? = nil
        public var useInputLanguage: Bool = false
        public init() {}
    }

    /// Build the user-side prompt for additive (ADD-only) extraction with
    /// linking. Port of `generate_additive_extraction_prompt`.
    public static func generateAdditiveExtractionPrompt(_ args: AdditivePromptArgs) -> String {
        let currentDate = args.currentDate ?? todayUTC()
        let observationDate = args.observationDate ?? currentDate

        var sections: [String] = []
        sections.append("## Summary\n\(args.summary)")
        sections.append("## Last k Messages\n\(formatConversationHistory(args.lastKMessages))")
        sections.append("## Recently Extracted Memories\n\(serializeMemories(args.recentlyExtractedMemories))")
        sections.append("## Existing Memories\n\(serializeMemories(args.existingMemories))")
        sections.append("## New Messages\n\(args.newMessages)")
        sections.append("## Observation Date\n\(observationDate)")
        sections.append("## Current Date\n\(currentDate)")

        if let ci = args.customInstructions, !ci.isEmpty {
            sections.append("## Custom Instructions\n\(ci)")
        }
        if args.useInputLanguage {
            sections.append("""
            ## Language Requirement
            CRITICAL: Respond in the SAME LANGUAGE and SCRIPT as the input messages.
            1. Match the language of the user's messages exactly.
            2. Preserve the exact script/alphabet of the input.
            3. Do NOT translate or transliterate into English unless the input is English.
            4. Maintain all quality standards regardless of language.
            """)
        }
        sections.append("# Output:")
        return sections.joined(separator: "\n\n")
    }

    /// Build the update-memory decision prompt. Port of `get_update_memory_messages`.
    public static func getUpdateMemoryMessages(retrievedOldMemory: [JSONValue],
                                               responseContent: [JSONValue],
                                               customUpdateMemoryPrompt: String? = nil) -> String {
        let base = customUpdateMemoryPrompt ?? Mem0PromptConstants.defaultUpdateMemoryPrompt
        let currentMemoryPart: String
        if !retrievedOldMemory.isEmpty {
            currentMemoryPart = """

                Below is the current content of my memory which I have collected till now. You have to update it in the following format only:

                ```
                \(serializeMemories(retrievedOldMemory))
                ```

                
            """
        } else {
            currentMemoryPart = "\n    Current memory is empty.\n\n    "
        }

        return """
        \(base)

            \(currentMemoryPart)

            The new retrieved facts are mentioned in the triple backticks. You have to analyze the new retrieved facts and determine whether these facts should be added, updated, or deleted in the memory.

            ```
            \(serializeMemories(responseContent))
            ```

            You must return your response in the following JSON structure only:

            {
                "memory" : [
                    {
                        "id" : "<ID of the memory>",
                        "text" : "<Content of the memory>",
                        "event" : "<Operation to be performed>",
                        "old_memory" : "<Old memory content>"
                    },
                    ...
                ]
            }

            Do not return anything except the JSON format.
        """
    }
}