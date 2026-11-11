import SwiftUI

extension ObsidianExportMode {
    var title: String {
        switch self {
        case .separateFiles: L("Separate file per meeting")
        case .worklog: L("Worklog")
        case .filesAndIndex: L("Files and index")
        }
    }
}

struct ObsidianLayoutSettingsView: View {
    let coordinator: ObsidianExportCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ObsidianExportMode
    @State private var folder: String
    @State private var layout: ObsidianExportLayout
    @State private var legacyPath: String?
    @State private var legacySections: [ObsidianWorklogPlacement.LegacyRuntimeDay] = []
    @State private var legacyYears: [String: String] = [:]
    @State private var preview: String?
    @State private var issue: String?
    @State private var loading = false

    init(coordinator: ObsidianExportCoordinator) {
        self.coordinator = coordinator
        let destination = coordinator.destination ?? ObsidianDestinationRecord()
        _mode = State(initialValue: destination.mode)
        _folder = State(initialValue: destination.meetingFolder)
        _layout = State(initialValue: destination.layout)
    }

    var body: some View {
        VStack(spacing: 12) {
            Form {
                Picker(L("Format"), selection: $mode) {
                    ForEach(ObsidianExportMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if mode != .worklog { TextField(L("Meeting folder"), text: $folder) }
                if mode != .separateFiles {
                    TextField(L("Worklog or index path"), text: $layout.documentPath)
                    Toggle(L("One document per month"), isOn: $layout.monthly)
                    Picker(L("Export time zone"), selection: $layout.timeZoneID) {
                        ForEach(Set(TimeZone.knownTimeZoneIdentifiers + [layout.timeZoneID]).sorted(), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    TextField(L("Start after this exact line"), text: optional(\.startAfter))
                    TextField(L("End before this exact line"), text: optional(\.endBefore))
                    Toggle(L("Group by day"), isOn: $layout.groupByDay)
                    if layout.groupByDay {
                        Toggle(L("Newest days first"), isOn: $layout.newestDaysFirst)
                        Toggle(L("Insert at beginning of day"), isOn: $layout.withinDayAtBeginning)
                    } else {
                        Toggle(L("Insert at beginning"), isOn: $layout.insertAtBeginning)
                    }
                    if mode == .worklog {
                        Button(L("Use Runtime format")) {
                            layout.applyRuntimePreset()
                            if layout.documentPath == "Meeting worklog.md" { layout.documentPath = "Runtime.md" }
                        }
                        Toggle(L("Runtime day headings"), isOn: $layout.runtimeStyle)
                        if layout.runtimeStyle, layout.groupByDay {
                            legacyYearFields
                        }
                    }
                }
                HStack {
                    section(L("Notes"), .notes)
                    section(L("Summary"), .summary)
                    section(L("Decisions"), .decisions)
                    section(L("Tasks"), .tasks)
                    section(L("Open questions"), .questions)
                }
            }.formStyle(.grouped).disabled(loading)
            if let issue { Text(issue).foregroundStyle(.red).padding(.horizontal, 16) }
            if let preview {
                ScrollView {
                    Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(height: 135).background(.quaternary.opacity(0.35))
                    .padding(.horizontal, 16)
            }
            HStack {
                if loading { ProgressView().controlSize(.small) }
                Button(L("Preview placement"), action: makePreview).disabled(loading)
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.disabled(loading)
                Button(L("Save")) {
                    coordinator.setLayout(mode: mode, meetingFolder: folder, layout: confirmedLayout)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(preview == nil || loading)
            }.padding([.horizontal, .bottom], 16)
        }.frame(width: 620, height: 650)
            .onChange(of: mode) { value in
                if value == .filesAndIndex, layout.documentPath == "Meeting worklog.md" { layout.documentPath = "Meeting index.md" }
                if value == .worklog, layout.documentPath == "Meeting index.md" { layout.documentPath = "Meeting worklog.md" }
                resetPreview()
            }
            .onChange(of: folder) { _ in resetPreview() }
            .onChange(of: layout) { _ in resetPreview() }
            .onChange(of: legacyScope) { _ in
                legacyPath = nil
                legacySections = []
                legacyYears = [:]
            }
    }

    private struct LegacyScope: Equatable {
        let mode: ObsidianExportMode
        let path: String
        let monthly: Bool
        let timeZoneID: String
        let startAfter: String?
        let endBefore: String?
        let active: Bool
    }

    private var legacyScope: LegacyScope {
        LegacyScope(mode: mode, path: layout.documentPath, monthly: layout.monthly, timeZoneID: layout.timeZoneID,
            startAfter: layout.startAfter, endBefore: layout.endBefore, active: layout.groupByDay && layout.runtimeStyle)
    }

    @ViewBuilder private var legacyYearFields: some View {
        if legacySections.isEmpty {
            Text(L("Preview placement to confirm the year for each existing day heading."))
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(legacySections) { section in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).fontWeight(.semibold)
                    Text(L("Line %ld", section.lineNumber)).font(.caption).foregroundStyle(.secondary)
                    if let context = section.context {
                        Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                TextField(L("Year"), text: Binding(get: { legacyYears[section.id] ?? "" }, set: { value in
                    legacyYears[section.id] = value
                    resetPreview()
                }))
                .textFieldStyle(.roundedBorder).frame(width: 90)
                .accessibilityLabel(L("Year for %@, line %ld", section.title, section.lineNumber))
            }
        }
    }

    private var confirmedLayout: ObsidianExportLayout {
        var value = layout
        guard let legacyPath, !legacySections.isEmpty else { return value }
        var byFile = value.legacyRuntimeYears ?? [:]
        byFile[legacyPath] = Dictionary(uniqueKeysWithValues: legacySections.compactMap { section in
            let text = legacyYears[section.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Int(text).map { (section.id, $0) }
        })
        value.legacyRuntimeYears = byFile
        return value
    }

    private func resetPreview() { preview = nil; issue = nil }

    private func optional(_ path: WritableKeyPath<ObsidianExportLayout, String?>) -> Binding<String> {
        Binding(get: { layout[keyPath: path] ?? "" }, set: { layout[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func section(_ title: String, _ section: MeetingMarkdownSections) -> some View {
        Toggle(title, isOn: Binding(get: { layout.sections.contains(section) }, set: { enabled in
            if enabled { layout.sections.insert(section) } else { layout.sections.remove(section) }
        }))
    }

    private func makePreview() {
        resetPreview()
        for section in legacySections {
            let input = legacyYears[section.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !input.isEmpty, Int(input).flatMap(section.dateKey(year:)) == nil {
                issue = L("Enter a valid year for %@ on line %ld.", section.title, section.lineNumber)
                return
            }
        }
        let layout = confirmedLayout
        var destination = coordinator.destination ?? ObsidianDestinationRecord()
        destination.mode = mode
        destination.meetingFolder = folder
        destination.layout = layout
        let candidate = destination
        loading = true
        Task { @MainActor in
            defer { loading = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ObsidianLayoutPreview.render(candidate)
                }.value
                legacyPath = result.path
                legacySections = result.legacyDays
                let previous = result.path.flatMap { candidate.layout.legacyRuntimeYears?[$0] } ?? [:]
                legacyYears = Dictionary(uniqueKeysWithValues: result.legacyDays.compactMap { section in
                    previous[section.id].map { (section.id, String($0)) }
                })
                preview = result.text
                issue = result.issue
            } catch { issue = error.localizedDescription }
        }
    }
}

private enum ObsidianLayoutPreview {
    struct Snapshot: Sendable {
        var path: String? = nil
        var legacyDays: [ObsidianWorklogPlacement.LegacyRuntimeDay] = []
        var text: String?
        var issue: String? = nil
    }

    static func render(_ destination: ObsidianDestinationRecord) throws -> Snapshot {
        if destination.mode != .worklog, !destination.meetingFolder.isEmpty {
            try validate(destination.meetingFolder, file: false)
        }
        if destination.mode != .separateFiles { try validate(destination.layout.documentPath, file: true) }
        let sample = MeetingSessionRecord(title: L("Example meeting"), startedAt: Date())
        let snapshot = ObsidianExportSnapshot(session: sample, note: nil, outcome: nil, outcomeState: .notStarted)
        let components = destination.mode.requiredComponents
        let paths = components.map { ObsidianComponentRenderer.relativePath(for: $0, destination: destination, snapshot: snapshot) }
        var result = paths
        guard let shared = components.last, shared != .meeting, let path = paths.last else {
            return Snapshot(text: result.joined(separator: "\n"))
        }
        var source = [destination.layout.startAfter, destination.layout.endBefore].compactMap { $0 }.joined(separator: "\n")
        if let bookmark = destination.vaultBookmark, case .granted(let root) = ObsidianVaultAccess.resolve(bookmark) {
            defer { root.stopAccessingSecurityScopedResource() }
            let target = try ObsidianVaultAccess.validate(relativePath: path, in: root).get()
            _ = try ObsidianVaultAccess.validateFileTarget(target).get()
            do {
                source = try String(contentsOf: target, encoding: .utf8)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                source = ""
            }
        } else {
            result.append(L("Example placement. The vault is unavailable for preview."))
        }
        let legacyDays = try ObsidianWorklogPlacement.legacyRuntimeDays(
            in: MarkdownStructureScanner.scan(source), layout: destination.layout)
        let nonce = ManagedBlock.newNonce()
        let binding = ObsidianExportBindingRecord(destinationID: destination.id, sessionID: sample.id, component: shared,
            relativePath: path, markerID: nonce, lastExportedRevision: 0, lastBlockSHA256: nil, lastFileSHA256: nil,
            state: .idle, errorCode: nil, updatedAt: Date())
        let patched: String
        do {
            patched = try ObsidianComponentRenderer.patch(existing: source, binding: binding, destination: destination,
                snapshot: snapshot, meetingRelativePath: shared == .index ? paths.first : nil).text
        } catch let error as ObsidianExportError {
            if case .placementConflict = error, !legacyDays.isEmpty {
                return Snapshot(path: path, legacyDays: legacyDays, text: nil, issue: error.localizedDescription)
            }
            throw error
        }
        if let marker = patched.range(of: ManagedBlock.beginMarker(sessionID: sample.id, nonce: nonce, component: shared)) {
            let start = patched.index(marker.lowerBound, offsetBy: -900, limitedBy: patched.startIndex) ?? patched.startIndex
            let end = patched.index(marker.upperBound, offsetBy: 1600, limitedBy: patched.endIndex) ?? patched.endIndex
            result.append(String(patched[start..<end]))
        }
        return Snapshot(path: path, legacyDays: legacyDays, text: result.joined(separator: "\n\n"))
    }

    private static func validate(_ path: String, file: Bool) throws {
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\:*?\"<>|"))
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".obsidian" ||
                $0.rangeOfCharacter(from: invalid) != nil || $0.utf8.count > 240
        }), !file || (path as NSString).pathExtension.lowercased() == "md" else {
            throw ObsidianExportError.pathEscapesVault(path)
        }
    }
}
