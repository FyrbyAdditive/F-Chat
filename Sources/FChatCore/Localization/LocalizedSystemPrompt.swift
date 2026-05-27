import Foundation

public enum PromptLanguage: String, Sendable, Hashable, CaseIterable, Codable {
    case english = "en"
    case swedish = "sv"

    public static func resolve(from locale: Locale = .current) -> PromptLanguage {
        let code = locale.language.languageCode?.identifier ?? "en"
        return PromptLanguage(rawValue: code) ?? .english
    }
}

public struct LocalizedSystemPrompt: Sendable, Hashable {
    public var language: PromptLanguage
    public var includeToolGuidance: Bool
    public var includeRAGGuidance: Bool
    public var customSuffix: String?
    /// Replaces the built-in F-Chat preamble. nil = use the localised
    /// default. Tool / RAG guidance is still auto-appended when their
    /// flags are set, so custom agents keep working with tools and RAG.
    public var basePromptOverride: String?

    public init(
        language: PromptLanguage = .english,
        includeToolGuidance: Bool = true,
        includeRAGGuidance: Bool = false,
        customSuffix: String? = nil,
        basePromptOverride: String? = nil
    ) {
        self.language = language
        self.includeToolGuidance = includeToolGuidance
        self.includeRAGGuidance = includeRAGGuidance
        self.customSuffix = customSuffix
        self.basePromptOverride = basePromptOverride
    }

    public func render() -> String {
        var parts: [String] = []
        if let override = basePromptOverride, !override.isEmpty {
            parts.append(override)
        } else {
            parts.append(Strings.base(for: language))
        }
        if includeToolGuidance { parts.append(Strings.toolGuidance(for: language)) }
        if includeRAGGuidance { parts.append(Strings.ragGuidance(for: language)) }
        if let suffix = customSuffix, !suffix.isEmpty { parts.append(suffix) }
        return parts.joined(separator: "\n\n")
    }

    /// The built-in F-Chat preamble for a given language, without any
    /// tool / RAG guidance or custom suffix. Used by Settings → Agents to
    /// show the user what the Default agent's prompt actually says (and
    /// to pre-populate the editor when overriding it).
    public static func builtInPreamble(for language: PromptLanguage) -> String {
        Strings.base(for: language)
    }

    private enum Strings {
        static func base(for language: PromptLanguage) -> String {
            switch language {
            case .english:
                return """
                You are F-Chat, a helpful native macOS assistant. \
                Be concise, accurate, and direct. Cite sources when you use information \
                from web searches, fetched pages, or retrieved documents.
                """
            case .swedish:
                return """
                Du är F-Chat, en hjälpsam macOS-assistent. \
                Var kortfattad, korrekt och direkt. Svara på svenska om inte användaren \
                skriver på ett annat språk. Ange källor när du använder information från \
                webbsökningar, hämtade sidor eller indexerade dokument.
                """
            }
        }

        static func toolGuidance(for language: PromptLanguage) -> String {
            switch language {
            case .english:
                return """
                You may call the provided tools when they help answer the user's question. \
                Prefer fewer, well-formed calls over many small ones. Do not call a tool \
                if you already have the answer.
                """
            case .swedish:
                return """
                Du får använda de tillgängliga verktygen när de hjälper dig att svara. \
                Föredra färre välformulerade anrop framför många små. Anropa inte ett \
                verktyg om du redan vet svaret.
                """
            }
        }

        static func ragGuidance(for language: PromptLanguage) -> String {
            switch language {
            case .english:
                return """
                One or more document collections are attached to this chat. Use the \
                `rag_search` tool to look up information before answering questions that \
                might be covered by the attached material, and cite the document and \
                section in your response.
                """
            case .swedish:
                return """
                En eller flera dokumentsamlingar är kopplade till denna chatt. Använd \
                verktyget `rag_search` för att slå upp information innan du svarar på \
                frågor som kan täckas av det bifogade materialet, och ange dokument och \
                avsnitt i ditt svar.
                """
            }
        }
    }
}
