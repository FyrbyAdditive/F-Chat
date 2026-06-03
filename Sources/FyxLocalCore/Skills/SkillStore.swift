// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import ZIPFoundation

/// Owns the on-disk storage for installed Agent Skills.
///
/// Layout under Application Support:
/// ```
/// …/FyxLocal/Skills/<skillID>/
///     SKILL.md
///     scripts/…              ← bundled executables, copied verbatim on import
///     <other bundled files>
///     work/                  ← per-invocation scratch the sandbox may write to
/// ```
///
/// The store is responsible for unpacking imports (folder or `.zip`),
/// validating the `SKILL.md` frontmatter, and exposing the directories the
/// code-execution sandbox needs. Metadata (the parsed `Skill` value) is
/// persisted separately in `state.json` by `AppEnvironment`; the bundled files
/// only live here on disk.
public struct SkillStore: Sendable {
    public let rootDirectory: URL

    public enum StoreError: Error, CustomStringConvertible {
        case noSkillManifest
        case multipleSkillManifests([String])
        case notAValidZip(String)
        case importFailed(String)

        public var description: String {
            switch self {
            case .noSkillManifest:
                return "The skill package does not contain a SKILL.md file."
            case .multipleSkillManifests(let paths):
                return "The skill package contains more than one SKILL.md (\(paths.joined(separator: ", "))); exactly one is required."
            case .notAValidZip(let detail):
                return "Could not read the skill .zip: \(detail)"
            case .importFailed(let detail):
                return "Could not import the skill: \(detail)"
            }
        }
    }

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? AppDataDirectories.subdirectory("Skills")
        try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Directories

    /// The unpacked root for a skill (contains SKILL.md + bundled files).
    public func skillRootDirectory(for id: SkillID) -> URL {
        rootDirectory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    }

    /// The per-skill scratch directory the sandbox may write to.
    public func workingDirectory(for id: SkillID) -> URL {
        skillRootDirectory(for: id).appendingPathComponent("work", isDirectory: true)
    }

    /// Path to a skill's SKILL.md on disk.
    public func manifestURL(for id: SkillID) -> URL {
        skillRootDirectory(for: id).appendingPathComponent("SKILL.md")
    }

    // MARK: - Import

    /// Import a skill from a directory containing a SKILL.md (the unpacked
    /// Agent Skills layout). Validates the frontmatter, copies the whole tree
    /// into a fresh `<skillID>/` directory, and returns the parsed `Skill`.
    @discardableResult
    public func importSkill(fromDirectory source: URL) throws -> Skill {
        let manifests = Self.findManifests(in: source)
        guard !manifests.isEmpty else { throw StoreError.noSkillManifest }
        guard manifests.count == 1 else {
            throw StoreError.multipleSkillManifests(manifests.map { $0.lastPathComponent })
        }
        // The skill's root is the directory containing SKILL.md (it may be a
        // subfolder if the package wraps everything in a top-level dir).
        let skillRoot = manifests[0].deletingLastPathComponent()
        let raw = try String(contentsOf: manifests[0], encoding: .utf8)
        let front = try SkillFrontmatter.parse(raw)
        let id = SkillID()
        let dest = skillRootDirectory(for: id)
        do {
            try copyTree(from: skillRoot, to: dest)
            try FileManager.default.createDirectory(at: workingDirectory(for: id), withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw StoreError.importFailed(error.localizedDescription)
        }
        return Skill(
            id: id,
            name: front.name,
            description: front.description,
            body: front.body,
            version: front.version,
            license: front.license,
            sourceKind: .imported
        )
    }

    /// Import a skill from a `.zip` archive (the packaged Agent Skills format).
    /// Unpacks to a temp dir, then delegates to `importSkill(fromDirectory:)`.
    @discardableResult
    public func importSkill(fromZip zipURL: URL) throws -> Skill {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-skill-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try Self.guardArchiveSize(zipURL)   // reject zip bombs before extracting
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: zipURL, to: temp)
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.notAValidZip(error.localizedDescription)
        }
        return try importSkill(fromDirectory: temp)
    }

    /// Reject zip bombs: cap the total uncompressed size and entry count of a
    /// skill archive before extracting it.
    private static func guardArchiveSize(_ zipURL: URL) throws {
        let maxTotalBytes: UInt64 = 256 * 1024 * 1024   // 256 MB extracted
        let maxEntries = 10_000
        guard let archive = try? Archive(url: zipURL, accessMode: .read) else {
            throw StoreError.notAValidZip("could not open archive")
        }
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            if count > maxEntries { throw StoreError.notAValidZip("archive has too many entries") }
            total = total.addingReportingOverflow(entry.uncompressedSize).partialValue
            if total > maxTotalBytes { throw StoreError.notAValidZip("archive expands too large") }
        }
    }

    /// Import from raw `.zip` bytes (e.g. an in-memory drop). Writes to a temp
    /// file and reuses the file-based path.
    @discardableResult
    public func importSkill(fromZipData data: Data) throws -> Skill {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fchat-skill-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try data.write(to: temp)
        } catch {
            throw StoreError.importFailed(error.localizedDescription)
        }
        return try importSkill(fromZip: temp)
    }

    // MARK: - Create

    /// Author a new skill from scratch: writes a minimal SKILL.md and returns
    /// the `Skill`. `body` is the markdown instruction text below the
    /// frontmatter.
    @discardableResult
    public func createSkill(name: String, description: String, body: String) throws -> Skill {
        let id = SkillID()
        let dest = skillRootDirectory(for: id)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory(for: id), withIntermediateDirectories: true)
        let manifest = Self.renderManifest(name: name, description: description, body: body)
        try manifest.write(to: manifestURL(for: id), atomically: true, encoding: .utf8)
        // Validate what we just wrote so a malformed name/description surfaces.
        _ = try SkillFrontmatter.parse(manifest)
        return Skill(
            id: id,
            name: name,
            description: description,
            body: body,
            sourceKind: .userCreated
        )
    }

    /// Rewrite a user-created skill's SKILL.md after an edit.
    public func rewriteManifest(for skill: Skill) throws {
        let manifest = Self.renderManifest(name: skill.name, description: skill.description, body: skill.body)
        let dir = skillRootDirectory(for: skill.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: manifestURL(for: skill.id), atomically: true, encoding: .utf8)
    }

    // MARK: - Delete

    public func deleteSkill(_ id: SkillID) {
        try? FileManager.default.removeItem(at: skillRootDirectory(for: id))
    }

    /// Empty a skill's scratch dir between runs (best effort). Recreates it.
    public func resetWorkingDirectory(for id: SkillID) {
        let work = workingDirectory(for: id)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    /// Relative paths of the bundled files in a skill (for the import preview).
    public func bundledFiles(for id: SkillID) -> [String] {
        let root = skillRootDirectory(for: id)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var out: [String] = []
        // Standardize the root (resolve /var → /private/var etc.) so the
        // prefix matches the enumerator's canonicalised URLs.
        let rootStd = (root.resolvingSymlinksInPath().path as NSString).standardizingPath
        let prefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
        for case let url as URL in en {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let pathStd = (url.resolvingSymlinksInPath().path as NSString).standardizingPath
            var rel = pathStd
            if rel.hasPrefix(prefix) { rel.removeFirst(prefix.count) }
            // Hide the scratch dir from the preview.
            if rel == "work" || rel.hasPrefix("work/") { continue }
            out.append(rel)
        }
        return out.sorted()
    }

    // MARK: - Internals

    /// Locate every SKILL.md under a directory tree (case-insensitive on the
    /// filename). Packages sometimes wrap the skill in a top-level folder, so
    /// we search recursively rather than only at the root.
    static func findManifests(in dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in en {
            // Skip macOS resource-fork junk inside zips.
            if url.path.contains("__MACOSX") { continue }
            if url.lastPathComponent.lowercased() == "skill.md" {
                found.append(url)
            }
        }
        return found
    }

    /// Whether a tree-relative path is safe to append under the destination —
    /// i.e. it's not absolute and contains no `..` traversal component. Used to
    /// reject zip-slip entries before copying. `internal` so it's unit-testable.
    static func isSafeRelativePath(_ rel: String) -> Bool {
        if rel.isEmpty { return false }
        if rel.hasPrefix("/") { return false }              // absolute
        let components = rel.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains("..")                   // any `..` segment
    }

    private func copyTree(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let en = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        // Canonicalize the destination root once so we can verify every target
        // resolves to a path *inside* it (zip-slip / path-traversal defense).
        let destRoot = dest.standardizedFileURL.resolvingSymlinksInPath().path
        let destRootPrefix = destRoot.hasSuffix("/") ? destRoot : destRoot + "/"
        for case let url as URL in en {
            if url.path.contains("__MACOSX") { continue }
            var rel = url.path
            if rel.hasPrefix(prefix) { rel.removeFirst(prefix.count) } else { continue }
            // Reject traversal: a malicious skill archive could carry entries like
            // `../../evil` or absolute paths. `appendingPathComponent` does NOT
            // canonicalize, so these would otherwise write outside `dest`.
            guard Self.isSafeRelativePath(rel) else { continue }
            let target = dest.appendingPathComponent(rel)
            // Belt-and-braces: verify the resolved target is contained in dest,
            // catching any traversal the textual check missed (incl. symlinks in
            // the unpacked tree whose canonical path escapes the root).
            let resolvedTarget = target.standardizedFileURL.path
            guard resolvedTarget == destRoot || resolvedTarget.hasPrefix(destRootPrefix) else {
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    static func renderManifest(name: String, description: String, body: String) -> String {
        // Quote the description so colons / special chars in it don't break
        // the minimal YAML parser; escape embedded double quotes.
        let escapedDesc = description.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        ---
        name: \(name)
        description: "\(escapedDesc)"
        ---

        \(body)
        """
    }
}
