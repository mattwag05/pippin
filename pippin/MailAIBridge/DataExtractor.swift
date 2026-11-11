import Foundation

public enum DataExtractor {
    /// The JSON shape `ExtractionResult` decodes.
    static let outputSchema = AIOutputSchema.object([
        AIOutputField("dates", .array(.object([
            AIOutputField("text", .string),
            AIOutputField("isoDate", .string, optional: true),
            AIOutputField("context", .string),
        ]))),
        AIOutputField("amounts", .array(.object([
            AIOutputField("text", .string),
            AIOutputField("value", .number, optional: true),
            AIOutputField("currency", .string, optional: true),
            AIOutputField("context", .string),
        ]))),
        AIOutputField("trackingNumbers", .array(.string)),
        AIOutputField("actionItems", .array(.string)),
        AIOutputField("contacts", .array(.object([
            AIOutputField("name", .string, optional: true),
            AIOutputField("email", .string, optional: true),
            AIOutputField("phone", .string, optional: true),
        ]))),
        AIOutputField("urls", .array(.string)),
    ])

    public static func extract(
        messageBody: String,
        subject: String,
        provider: any AIProvider
    ) throws -> ExtractionResult {
        let userPrompt = "Subject: \(subject)\n\n\(messageBody)"
        let response = try provider.complete(
            prompt: userPrompt,
            system: MailAIPrompts.extractionSystemPrompt,
            options: AICompletionOptions(jsonMode: true, schema: outputSchema)
        )

        let stripped = stripAIResponseJSON(response)

        do {
            return try JSONDecoder().decode(ExtractionResult.self, from: Data(stripped.utf8))
        } catch {
            throw MailAIError.malformedAIResponse(response) // raw response, not stripped
        }
    }
}
