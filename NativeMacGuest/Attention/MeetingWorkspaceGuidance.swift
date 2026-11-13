import Combine
import ConferenceCore
import Foundation

/// Future participation instructions, scoped independently of per-session history.
@MainActor
final class MeetingWorkspaceGuidance: ObservableObject {
    enum Scope: Codable, Hashable {
        case allMeetings
        case calendarSeries(String)
        case room(String)

        var title: String {
            switch self {
            case .allMeetings: L("All my meetings")
            case .calendarSeries: L("This calendar series")
            case .room: L("This meeting room")
            }
        }

        var eventSource: String {
            switch self {
            case .allMeetings: "reviewGlobal"
            case .calendarSeries: "reviewSeries"
            case .room: "reviewRoom"
            }
        }

        func label(in sessions: [MeetingWorkspaceSession]) -> String {
            let session = sessions.first { session in
                switch self {
                case .allMeetings: false
                case .calendarSeries(let id): session.calendarSeriesID == id
                case .room(let id): session.roomRuleKey == id
                }
            }
            return session.map { L("%@ · %@", title, $0.title) } ?? title
        }
    }

    struct Rule: Codable, Hashable {
        let scope: Scope
        let text: String
    }

    enum SaveError: LocalizedError {
        case unreadable, empty, tooLong, scopeFull

        var errorDescription: String? {
            switch self {
            case .unreadable: L("Saved guidance could not be read.")
            case .empty: L("Enter guidance to save.")
            case .tooLong: L("Use up to %ld characters per instruction.", MeetingWorkspaceGuidance.maximumLength)
            case .scopeFull: L("This scope has reached its saved guidance limit.")
            }
        }
    }

    nonisolated static let maximumLength = 600
    nonisolated static let maximumScopeLength = 3_600
    private let url: URL
    @Published private(set) var rules: [Rule] = []
    private var readable = true
    private var scopeRevisions: [Scope: UUID] = [:]

    init(root: URL) {
        url = root.appendingPathComponent("workspace-guidance.json")
        do {
            rules = try JSONDecoder().decode([Rule].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        } catch {
            readable = false
        }
    }

    static func roomKey(for model: NativeDesktopMeetingModel) -> String? {
        guard let room = MeetingRoomIdentity(model.invitation, engine: model.kind) else { return nil }
        let fields = [room.engine.rawValue, room.origin, room.room]
        return ParticipationContext.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }

    static func scopes(for model: NativeDesktopMeetingModel) -> [Scope] {
        [.allMeetings, roomKey(for: model).map(Scope.room),
         model.calendarSeriesID.map(Scope.calendarSeries)].compactMap { $0 }
    }

    func instructions(for model: NativeDesktopMeetingModel) -> [String] {
        let scopes = Self.scopes(for: model)
        return scopes.flatMap { scope in rules.filter { $0.scope == scope }.map(\.text) }
    }

    func revisions(for model: NativeDesktopMeetingModel) -> [UUID] {
        Self.scopes(for: model).compactMap { scopeRevisions[$0] }
    }

    @discardableResult
    func append(_ text: String, to scope: Scope) throws -> Bool {
        let clean = try validated(text)
        let rule = Rule(scope: scope, text: clean)
        if rules.contains(rule) { return false }
        let used = rules.filter { $0.scope == scope }.reduce(0) { $0 + $1.text.count }
        guard used + clean.count <= Self.maximumScopeLength else { throw SaveError.scopeFull }
        try save(rules + [rule])
        return true
    }

    func remove(_ rule: Rule) throws {
        guard readable else { throw SaveError.unreadable }
        try save(rules.filter { $0 != rule })
    }

    func replace(_ rule: Rule, text: String) throws {
        let clean = try validated(text)
        guard let index = rules.firstIndex(of: rule), rule.text != clean else { return }
        let changed = Rule(scope: rule.scope, text: clean)
        if rules.contains(changed) { try remove(rule); return }
        let used = rules.filter { $0.scope == rule.scope }.reduce(0) { $0 + $1.text.count }
        guard used - rule.text.count + clean.count <= Self.maximumScopeLength else { throw SaveError.scopeFull }
        var updated = rules
        updated[index] = changed
        try save(updated)
    }

    private func validated(_ text: String) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard readable else { throw SaveError.unreadable }
        guard !clean.isEmpty else { throw SaveError.empty }
        guard clean.count <= Self.maximumLength else { throw SaveError.tooLong }
        return clean
    }

    private func save(_ updated: [Rule]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        let scopes = Set(rules.map(\.scope)).union(updated.map(\.scope))
        for scope in scopes where rules.filter({ $0.scope == scope }) != updated.filter({ $0.scope == scope }) {
            scopeRevisions[scope] = UUID()
        }
        rules = updated
    }
}
