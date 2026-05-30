// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import SwiftUI
import UniformTypeIdentifiers
import FChatCore

/// Settings → Skills. The global library of Agent Skills: import third-party
/// `SKILL.md` packages (folder or `.zip`) or author one, toggle which apply to
/// every chat by default, and delete. Per-chat enablement happens in the
/// Inspector's Skills section.
struct SkillsTab: View {
    @Bindable var environment: AppEnvironment
    @State private var showAddSheet = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var pendingDeletion: SkillID?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.top)
            Divider().padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if environment.skills.isEmpty {
                        Text("No skills yet. Import a third-party skill package, or create one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach($environment.skills) { $skill in
                        SkillCard(
                            skill: $skill,
                            environment: environment,
                            onDelete: { pendingDeletion = skill.id }
                        )
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    showImporter = true
                } label: {
                    Label("Import skill", systemImage: "square.and.arrow.down")
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("Create skill", systemImage: "plus")
                }
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.folder, .zip],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showAddSheet) {
            AddSkillSheet(environment: environment, isPresented: $showAddSheet)
        }
        .confirmDeletion(
            for: $pendingDeletion,
            title: { id in
                let name = environment.skills.first(where: { $0.id == id })?.name ?? ""
                return "Delete skill \"\(name)\"?"
            },
            message: { id in
                let count = environment.chatCountUsingSkill(id)
                if count > 0 {
                    Text("\(count) chats currently use this skill.")
                } else {
                    Text("This skill isn't enabled in any chat.")
                }
            },
            onConfirm: { environment.deleteSkill($0) }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Skills")
                .font(.callout.bold())
            Text("Skills are folders of instructions and scripts the model can use. Imported skills run in a sandbox with no network access. Enable a skill per-chat in the Inspector, or mark it as applying to every chat below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            guard let url = try result.get().first else { return }
            // A security-scoped resource for sandboxed-picker URLs; harmless
            // when the app isn't sandboxed.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try environment.importSkill(from: url)
        } catch {
            importError = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
        }
    }
}

private struct SkillCard: View {
    @Binding var skill: Skill
    @Bindable var environment: AppEnvironment
    let onDelete: () -> Void
    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                skillDetail.padding(.top, 6)
            } label: {
                cardHeader
            }
        }
        .onChange(of: skill) { _, new in
            environment.updateSkill(new)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.headline)
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete skill")
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var skillDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Apply to every chat by default", isOn: $skill.enabledByDefault)
                .font(.callout)

            if let version = skill.version, !version.isEmpty {
                LabeledContent("Version") { Text(version).foregroundStyle(.secondary) }
                    .font(.caption)
            }
            if let license = skill.license, !license.isEmpty {
                LabeledContent("License") { Text(license).foregroundStyle(.secondary) }
                    .font(.caption)
            }
            LabeledContent("Source") {
                Text(skill.sourceKind == .imported ? "Imported" : "Created here")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            let files = environment.skillStore.bundledFiles(for: skill.id)
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bundled files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(files, id: \.self) { file in
                        Text(file)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct AddSkillSheet: View {
    @Bindable var environment: AppEnvironment
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var body_: String = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create skill").font(.title3.bold())
            LabeledContent("Name") {
                TextField("lowercase-with-hyphens", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Description") {
                TextField("When the model should use this skill", text: $description)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $body_)
                    .monospacedEditorBorder()
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            DialogActionButtons(
                confirmLabel: "Create",
                confirmDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: { isPresented = false },
                onConfirm: {
                    do {
                        _ = try environment.createSkill(name: name, description: description, body: body_)
                        isPresented = false
                    } catch {
                        self.error = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                    }
                }
            )
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}
