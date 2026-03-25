import Foundation

public enum DataExtractor {
    public static func extract(
        messageBody: String,
        subject: String,
        provider: any AIProvider
    ) throws -> ExtractionResult {
        let userPrompt = "Subject: \(subject)\n\n\(messageBody)"
        let response = try provider.complete(prompt: userPrompt, system: MailAIPrompts.extractionSystemPrompt)

        // Strip markdown fences (same pattern as PromptInjectionScanner.scanWithAI)
        var stripped = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("```") {
            let lines = stripped.components(separatedBy: "\n")
            stripped = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !stripped.hasPrefix("{") {
            if let firstBrace = stripped.firstIndex(of: "{"),
               let lastBrace = stripped.lastIndex(of: "}") {
                stripped = String(stripped[firstBrace...lastBrace])
            }
        }

        do {
            return try JSONDecoder().decode(ExtractionResult.self, from: Data(stripped.utf8))
        } catch {
            throw MailAIError.malformedAIResponse(response) // raw response, not stripped
        }
    }
}
