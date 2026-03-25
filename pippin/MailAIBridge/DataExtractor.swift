import Foundation

public enum DataExtractor {
    public static func extract(
        messageBody: String,
        subject: String,
        provider: any AIProvider
    ) throws -> ExtractionResult {
        let userPrompt = "Subject: \(subject)\n\n\(messageBody)"
        let response = try provider.complete(prompt: userPrompt, system: MailAIPrompts.extractionSystemPrompt)

        let stripped = stripAIResponseJSON(response)

        do {
            return try JSONDecoder().decode(ExtractionResult.self, from: Data(stripped.utf8))
        } catch {
            throw MailAIError.malformedAIResponse(response) // raw response, not stripped
        }
    }
}
