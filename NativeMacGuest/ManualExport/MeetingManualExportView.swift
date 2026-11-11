import AppKit
import SwiftUI

struct MeetingManualExportView: View {
    private enum Scope: Hashable { case meetings, period }

    @ObservedObject private var library: MeetingLibraryController
    @StateObject private var exporter: MeetingManualExportController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var selected: Set<UUID>
    @State private var scope = Scope.meetings
    @State private var from = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var through = Date()
    @State private var options = MeetingManualExportOptions()
    private let singleSessionID: UUID?

    init(attention: AttentionCoordinator, singleSessionID: UUID? = nil) {
        let library = attention.store.meetingLibrary
        _library = ObservedObject(wrappedValue: library)
        _exporter = StateObject(wrappedValue: MeetingManualExportController(library: library, notes: attention.store.notes,
            flushOutcomeWrites: { await attention.store.waitForOutcomeWrites() }))
        self.singleSessionID = singleSessionID
        _selected = State(initialValue: Set(singleSessionID.map { [$0] } ?? []))
    }

    private var displayCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }

    private var selectedCards: [MeetingLibraryCard] {
        library.cards.filter { card in
            switch scope {
            case .meetings: return selected.contains(card.sessionID)
            case .period:
                let date = card.effectiveDate?.date
                return MeetingManualExport.periodIncludes(date, from: from, through: through, calendar: displayCalendar)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Export Markdown")).font(.headline)
            if let results = exporter.results {
                resultList(results)
                HStack {
                    Spacer()
                    Button(L("Close")) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                if singleSessionID == nil { selection }
                formatOptions
                Divider()
                HStack {
                    Text(L("Meetings selected: %ld", selectedCards.count)).foregroundStyle(.secondary)
                    Spacer()
                    if exporter.exporting { ProgressView().controlSize(.small) }
                    Button(L("Cancel"), role: .cancel) { dismiss() }.disabled(exporter.exporting)
                    Button(L("Choose Folder…")) {
                        var settings = options
                        settings.calendar = displayCalendar
                        let cards = selectedCards
                        Task { await exporter.export(cards: cards, options: settings) }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(selectedCards.isEmpty || options.sections.isEmpty || exporter.exporting)
                }
            }
        }.padding(20).frame(width: 550)
            .interactiveDismissDisabled(exporter.exporting)
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Selection"), selection: $scope) {
                Text(L("Select meetings")).tag(Scope.meetings)
                Text(L("Date range")).tag(Scope.period)
            }.pickerStyle(.segmented).labelsHidden()
            switch scope {
            case .meetings:
                List(library.cards) { card in
                    Toggle(isOn: Binding(get: { selected.contains(card.sessionID) }, set: { checked in
                        if checked { selected.insert(card.sessionID) } else { selected.remove(card.sessionID) }
                    })) {
                        HStack {
                            Text(card.title).lineLimit(1)
                            Spacer()
                            let date = card.effectiveDate?.date
                            Text(date?.formatted(date: .abbreviated, time: .shortened) ?? L("Date unknown"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(height: 220)
                HStack {
                    Button(L("Select all")) { selected = Set(library.cards.map(\.sessionID)) }
                    Button(L("Clear selection")) { selected.removeAll() }
                }
            case .period:
                HStack {
                    DatePicker(L("From"), selection: $from, displayedComponents: .date)
                    DatePicker(L("Through"), selection: $through, displayedComponents: .date)
                }
                if displayCalendar.startOfDay(for: from) > displayCalendar.startOfDay(for: through) {
                    Text(L("The end date must be on or after the start date.")).foregroundStyle(.red)
                }
            }
        }.disabled(exporter.exporting)
    }

    private var formatOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if singleSessionID == nil {
                Picker(L("Format"), selection: $options.format) {
                    Text(L("Separate files")).tag(MeetingManualExportFormat.files)
                    Text(L("Worklog")).tag(MeetingManualExportFormat.worklog)
                    Text(L("Files and index")).tag(MeetingManualExportFormat.filesWithIndex)
                }
                if options.format != .files {
                    Toggle(L("One document per month"), isOn: $options.byMonth)
                }
                if options.format == .worklog {
                    Toggle(L("Group by day"), isOn: $options.groupByDay)
                    if options.groupByDay {
                        Toggle(L("Newest days first"), isOn: $options.newestDaysFirst)
                    }
                    Toggle(L("Newest meetings first"), isOn: $options.newestMeetingsFirst)
                }
            }
            HStack(spacing: 10) {
                sectionToggle(L("Notes"), section: .notes)
                sectionToggle(L("Summary"), section: .summary)
                sectionToggle(L("Decisions"), section: .decisions)
                sectionToggle(L("Tasks"), section: .tasks)
                sectionToggle(L("Open questions"), section: .questions)
            }
        }.disabled(exporter.exporting)
    }

    private func sectionToggle(_ title: String, section: MeetingMarkdownSections) -> some View {
        Toggle(title, isOn: Binding(get: { options.sections.contains(section) }, set: { included in
            if included { options.sections.insert(section) } else { options.sections.remove(section) }
        }))
    }

    private func resultList(_ results: [MeetingManualExportFileResult]) -> some View {
        let saved = results.filter { $0.url != nil }
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Files saved: %ld · Failed: %ld", saved.count, results.count - saved.count))
                .foregroundStyle(.secondary)
            List(results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.name)
                    if let url = result.url {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link).font(.caption)
                    }
                    if let error = result.error {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }.padding(.vertical, 4)
            }.frame(minHeight: 140, maxHeight: 300)
        }
    }
}
