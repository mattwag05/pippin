import Foundation

// Weak: the package targets macOS 15, where FoundationModels does not exist.
@_weakLinked import FoundationModels

/// Apple's on-device Foundation Models (`ai.provider: apple`, pippin-npqt).
/// Free text uses a plain session response. `jsonMode` calls that carry an
/// `AICompletionOptions.schema` use guided generation, so the reply always
/// matches the feature's JSON shape; without a schema the reply is prompt-based
/// JSON, as on Claude.
public struct AppleFoundationModelsProvider: AIProvider {
    public init() {}

    public func complete(prompt: String, system: String) throws -> String {
        try complete(prompt: prompt, system: system, options: AICompletionOptions())
    }

    public func complete(prompt: String, system: String, options: AICompletionOptions) throws -> String {
        guard #available(macOS 26, *) else {
            throw AIProviderError.modelUnavailable("it requires macOS 26 or later")
        }
        if let reason = Self.unavailableReason() {
            throw AIProviderError.modelUnavailable(reason)
        }
        let schema = try options.jsonMode ? options.schema.map(Self.generationSchema) : nil
        let temperature = options.temperature
        return try waitForAsync(timeoutSeconds: aiRequestTimeoutSeconds()) {
            try await Self.respond(prompt: prompt, system: system, schema: schema, temperature: temperature)
        }
    }

    /// Doctor's view: nil when the model can run, otherwise why not.
    public static func availabilityProblem() -> String? {
        guard #available(macOS 26, *) else { return "it requires macOS 26 or later" }
        return unavailableReason()
    }

    /// The context window in tokens, or nil before macOS 26.
    public static func contextSize() -> Int? {
        guard #available(macOS 26, *) else { return nil }
        return SystemLanguageModel.default.contextSize
    }

    @available(macOS 26, *)
    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return "this Mac is not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
            case .modelNotReady: return "the model is not ready (still downloading or updating)"
            @unknown default: return "the system reports it unavailable"
            }
        }
    }

    // MARK: - Schema conversion

    @available(macOS 26, *)
    static func generationSchema(_ schema: AIOutputSchema) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(schema, name: "Response"), dependencies: [])
    }

    /// Named schemas (objects and choices) get path-derived names, because
    /// `GenerationSchema` rejects two types with the same name.
    @available(macOS 26, *)
    static func dynamicSchema(_ schema: AIOutputSchema, name: String) -> DynamicGenerationSchema {
        switch schema {
        case .string: return DynamicGenerationSchema(type: String.self)
        case .integer: return DynamicGenerationSchema(type: Int.self)
        case .number: return DynamicGenerationSchema(type: Double.self)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        case let .choice(values): return DynamicGenerationSchema(name: name, anyOf: values)
        case let .array(item, minCount, maxCount):
            return DynamicGenerationSchema(
                arrayOf: dynamicSchema(item, name: name + "Item"),
                minimumElements: minCount, maximumElements: maxCount
            )
        case let .object(fields):
            return DynamicGenerationSchema(name: name, properties: fields.map {
                DynamicGenerationSchema.Property(
                    name: $0.name, schema: dynamicSchema($0.schema, name: name + "_" + $0.name), isOptional: $0.optional
                )
            })
        }
    }

    // MARK: - Session

    @available(macOS 26, *)
    private static func respond(
        prompt: String, system: String, schema: GenerationSchema?, temperature: Double?
    ) async throws -> String {
        let session = LanguageModelSession(model: .default, instructions: system)
        let options = GenerationOptions(temperature: temperature)
        do {
            if let schema {
                return try await session.respond(to: prompt, schema: schema, includeSchemaInPrompt: true, options: options)
                    .content.jsonString
            }
            return try await session.respond(to: prompt, options: options).content
        } catch {
            throw mapError(error)
        }
    }

    @available(macOS 26, *)
    static func mapError(_ error: Error) -> Error {
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case let .contextSizeExceeded(info):
                    return AIProviderError.contextExceeded(limit: info.contextSize, tokens: info.tokenCount)
                case .guardrailViolation, .refusal: return AIProviderError.guardrailRefusal
                case .rateLimited: return AIProviderError.rateLimited(retryAfterSeconds: nil, "on-device model busy")
                case .timeout: return AIProviderError.timeout
                default: return AIProviderError.decodingFailed(error.localizedDescription)
                }
            }
            if case .assetsUnavailable = error as? SystemLanguageModel.Error {
                return AIProviderError.modelUnavailable("the model assets are not available")
            }
        }
        // macOS 26 reports the same conditions through GenerationError.
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return AIProviderError.contextExceeded(limit: SystemLanguageModel.default.contextSize, tokens: nil)
            case .guardrailViolation, .refusal: return AIProviderError.guardrailRefusal
            case .assetsUnavailable: return AIProviderError.modelUnavailable("the model assets are not available")
            case .rateLimited, .concurrentRequests:
                return AIProviderError.rateLimited(retryAfterSeconds: nil, "on-device model busy")
            default: return AIProviderError.decodingFailed(error.localizedDescription)
            }
        }
        return error
    }
}
