// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

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
    /// Agent Skills enabled for this chat. Each contributes a name +
    /// description to a compact "Available skills" section — progressive
    /// disclosure level 1. The model reads a skill's SKILL.md and runs its
    /// bundled scripts via the `run_code` tool when a skill is relevant.
    public var skills: [SkillSummary]

    public struct SkillSummary: Sendable, Hashable {
        public var name: String
        public var description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public init(
        language: PromptLanguage = .english,
        includeToolGuidance: Bool = true,
        includeRAGGuidance: Bool = false,
        customSuffix: String? = nil,
        basePromptOverride: String? = nil,
        skills: [SkillSummary] = []
    ) {
        self.language = language
        self.includeToolGuidance = includeToolGuidance
        self.includeRAGGuidance = includeRAGGuidance
        self.customSuffix = customSuffix
        self.basePromptOverride = basePromptOverride
        self.skills = skills
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
        if !skills.isEmpty { parts.append(Strings.skillsGuidance(for: language, skills: skills)) }
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
                You are F-Chat, a helpful native macOS assistant created by Fyrby \
                Additive. Be concise, accurate, and direct. Cite sources when you \
                use information from web searches, fetched pages, or retrieved \
                documents.
                """
            case .swedish:
                return """
                Du är F-Chat, en hjälpsam macOS-assistent skapad av Fyrby Additive. \
                Var kortfattad, korrekt och direkt. Svara på svenska om inte \
                användaren skriver på ett annat språk. Ange källor när du använder \
                information från webbsökningar, hämtade sidor eller indexerade \
                dokument.
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

        static func skillsGuidance(for language: PromptLanguage, skills: [SkillSummary]) -> String {
            let bullets = skills
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            switch language {
            case .english:
                return """
                The following skills are available to you. A skill is a folder \
                of instructions and scripts you can use when its description \
                matches the task:

                \(bullets)

                To use a skill, call the `run_code` tool with that skill's \
                name. Start by reading its instructions (`cat SKILL.md`), then \
                run its bundled scripts as the instructions direct. Only invoke \
                a skill when its description is clearly relevant.
                """
            case .swedish:
                return """
                Följande färdigheter ("skills") är tillgängliga för dig. En \
                färdighet är en mapp med instruktioner och skript som du kan \
                använda när dess beskrivning matchar uppgiften:

                \(bullets)

                Använd en färdighet genom att anropa verktyget `run_code` med \
                färdighetens namn. Börja med att läsa dess instruktioner \
                (`cat SKILL.md`) och kör sedan de medföljande skripten enligt \
                instruktionerna. Anropa endast en färdighet när dess beskrivning \
                är tydligt relevant.
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
