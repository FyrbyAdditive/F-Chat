// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation

/// An installed Agent Skill — an Anthropic-format `SKILL.md` package plus any
/// bundled scripts and resources. Skills live in a global library
/// (`AppEnvironment.skills`); each chat enables a subset via
/// `ChatSettings.enabledSkills`. Enabled skills' `name` + `description` are
/// injected into the system prompt (progressive-disclosure level 1); the
/// model then reads the full `body` (level 2) and runs bundled scripts via
/// the `run_code` tool (level 3).
///
/// The bundled files themselves are NOT stored on this value — they live on
/// disk under the `SkillStore` working directory keyed by `id`. Only the
/// parsed metadata + instruction body persist to `state.json`.
public struct Skill: Identifiable, Codable, Sendable, Hashable {
    public let id: SkillID
    /// Frontmatter `name`: lowercase letters/digits/hyphens, ≤64 chars.
    /// Used as the human-facing identifier the model passes to `run_code`.
    public var name: String
    /// Frontmatter `description`: non-empty, ≤1024 chars. The trigger text
    /// the model sees in the system prompt.
    public var description: String
    /// The markdown instruction body below the frontmatter (level 2).
    public var body: String
    /// Optional `metadata.version` from the frontmatter.
    public var version: String?
    /// Optional `license` from the frontmatter.
    public var license: String?
    /// Whether this skill is offered to every chat by default. Mirrors the
    /// "global list that applies to any chat" requirement; per-chat the user
    /// can still opt a default-on skill out via `enabledSkills`.
    public var enabledByDefault: Bool
    public var sourceKind: SourceKind
    public var createdAt: Date
    public var updatedAt: Date

    public enum SourceKind: String, Codable, Sendable, Hashable {
        /// Imported from a third-party folder or `.zip`.
        case imported
        /// Authored in F-Chat's Skills tab.
        case userCreated
    }

    public init(
        id: SkillID = SkillID(),
        name: String,
        description: String,
        body: String,
        version: String? = nil,
        license: String? = nil,
        enabledByDefault: Bool = false,
        sourceKind: SourceKind = .imported,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.body = body
        self.version = version
        self.license = license
        self.enabledByDefault = enabledByDefault
        self.sourceKind = sourceKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Tolerate older/partial state files: every field except id/name has a
    // sensible default so a state.json written before a given field existed
    // still decodes.
    private enum CodingKeys: String, CodingKey {
        case id, name, description, body, version, license, enabledByDefault, sourceKind, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(SkillID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.description = try c.decode(String.self, forKey: .description, default: "")
        self.body = try c.decode(String.self, forKey: .body, default: "")
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.license = try c.decodeIfPresent(String.self, forKey: .license)
        self.enabledByDefault = try c.decode(Bool.self, forKey: .enabledByDefault, default: false)
        self.sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind, default: .imported)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt, default: .now)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt, default: .now)
    }
}

/// The parsed contents of a `SKILL.md` file: validated frontmatter fields plus
/// the instruction body. Produced by ``SkillFrontmatter/parse(_:)`` and
/// consumed when constructing a ``Skill``.
public struct SkillFrontmatter: Sendable, Hashable {
    public var name: String
    public var description: String
    public var body: String
    public var version: String?
    public var license: String?

    public init(name: String, description: String, body: String, version: String? = nil, license: String? = nil) {
        self.name = name
        self.description = description
        self.body = body
        self.version = version
        self.license = license
    }

    /// Validation rules enforced against the Anthropic Agent Skills spec.
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingFrontmatter
        case malformedFrontmatter(String)
        case missingName
        case nameTooLong(Int)
        case nameInvalidCharacters
        case nameReservedWord(String)
        case missingDescription
        case descriptionTooLong(Int)
        case containsXMLTags(field: String)

        public var description: String {
            switch self {
            case .missingFrontmatter:
                return "SKILL.md must begin with a YAML frontmatter block delimited by `---`."
            case .malformedFrontmatter(let detail):
                return "Could not parse the SKILL.md frontmatter: \(detail)"
            case .missingName:
                return "SKILL.md frontmatter is missing a `name`."
            case .nameTooLong(let n):
                return "Skill `name` is \(n) characters; the maximum is 64."
            case .nameInvalidCharacters:
                return "Skill `name` may contain only lowercase letters, digits and hyphens."
            case .nameReservedWord(let word):
                return "Skill `name` may not contain the reserved word \"\(word)\"."
            case .missingDescription:
                return "SKILL.md frontmatter is missing a `description`."
            case .descriptionTooLong(let n):
                return "Skill `description` is \(n) characters; the maximum is 1024."
            case .containsXMLTags(let field):
                return "Skill `\(field)` may not contain XML/HTML tags."
            }
        }
    }

    public static let maxNameLength = 64
    public static let maxDescriptionLength = 1024
    private static let reservedWords = ["anthropic", "claude"]

    /// Parse and validate a raw `SKILL.md` document.
    public static func parse(_ raw: String) throws -> SkillFrontmatter {
        let (frontmatterText, body) = try splitFrontmatter(raw)
        let fields = try parseYAMLish(frontmatterText)

        guard let rawName = fields["name"], !rawName.isEmpty else {
            throw ParseError.missingName
        }
        let name = rawName
        guard name.count <= maxNameLength else { throw ParseError.nameTooLong(name.count) }
        let lowered = name.lowercased()
        for word in reservedWords where lowered.contains(word) {
            throw ParseError.nameReservedWord(word)
        }
        // Lowercase letters, digits, hyphens only.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ParseError.nameInvalidCharacters
        }
        if containsXMLTags(name) { throw ParseError.containsXMLTags(field: "name") }

        guard let description = fields["description"], !description.isEmpty else {
            throw ParseError.missingDescription
        }
        guard description.count <= maxDescriptionLength else {
            throw ParseError.descriptionTooLong(description.count)
        }
        if containsXMLTags(description) { throw ParseError.containsXMLTags(field: "description") }

        return SkillFrontmatter(
            name: name,
            description: description,
            body: body,
            version: fields["version"],
            license: fields["license"]
        )
    }

    // MARK: - Internals

    /// Split a document into its frontmatter text and the body that follows.
    /// The frontmatter is the block between the first `---` line and the next
    /// `---` line.
    static func splitFrontmatter(_ raw: String) throws -> (frontmatter: String, body: String) {
        // Normalise line endings so CRLF documents parse.
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalised.components(separatedBy: "\n")
        // Allow a leading BOM / blank lines before the opening fence.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard let opening = lines.first, opening.trimmingCharacters(in: .whitespaces) == "---" else {
            throw ParseError.missingFrontmatter
        }
        lines.removeFirst()
        var frontmatterLines: [String] = []
        var closed = false
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                closed = true
                index += 1
                break
            }
            frontmatterLines.append(line)
            index += 1
        }
        guard closed else {
            throw ParseError.malformedFrontmatter("the frontmatter block is not closed with `---`.")
        }
        let body = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontmatterLines.joined(separator: "\n"), body)
    }

    /// Minimal `key: value` YAML parser covering the flat scalar fields the
    /// Agent Skills frontmatter uses (name, description, license) plus the
    /// nested `metadata.version`. Not a general YAML implementation: skills
    /// frontmatter is intentionally simple, and a full YAML dependency would
    /// be overkill. Quoted values (single/double) are unquoted; a `metadata:`
    /// block's indented `version:` is hoisted to a flat `version` key.
    static func parseYAMLish(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        var inMetadata = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indented = line.first == " " || line.first == "\t"
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(value)

            if key == "metadata" && value.isEmpty {
                inMetadata = true
                continue
            }
            if inMetadata && indented {
                // Nested under metadata: pick up version (and pass others through
                // under their bare key, harmless if unused).
                result[key] = value
                continue
            }
            inMetadata = false
            if !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!, last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// True if the string contains something that looks like an XML/HTML tag
    /// (`<...>`). The spec forbids tags in `name`/`description` because they
    /// land verbatim in the system prompt.
    static func containsXMLTags(_ s: String) -> Bool {
        guard let open = s.firstIndex(of: "<") else { return false }
        let rest = s[s.index(after: open)...]
        guard let close = rest.firstIndex(of: ">") else { return false }
        // Require at least one non-space character between the brackets so a
        // bare "a < b" comparison isn't flagged.
        let inner = rest[..<close].trimmingCharacters(in: .whitespaces)
        return !inner.isEmpty
    }
}
