import ConferenceCore
import SwiftUI

struct IOSMeetingTaskEditor: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    let task: IOSMeetingTaskItem
    var onOpenSession: ((UUID) -> Void)?

    init(workspace: IOSWorkspaceCoordinator, task: IOSMeetingTaskItem, onOpenSession: ((UUID) -> Void)? = nil) {
        self.workspace = workspace
        self.task = task
        self.onOpenSession = onOpenSession
    }

    var body: some View {
        let session = workspace.sessions.first { $0.id == task.sessionID }
        let record = WorkspaceTaskRecord(
            id: task.id,
            sessionID: task.sessionID,
            outcomeID: task.outcomeID,
            meetingTitle: session?.title ?? L("Meeting"),
            meetingDate: session?.startedAt,
            text: task.text,
            owner: task.owner,
            assigneeID: task.assigneeID,
            dueDay: task.dueDay,
            dueAt: task.dueAt,
            reminderAt: task.reminderAt,
            done: task.done,
            completedAt: task.completedAt,
            archivedAt: workspace.taskArchiveDates[task.id],
            updatedAt: task.updatedAt,
            isOwnedByCurrentUser: workspace.taskProfile.owns(task),
            extended: task.extended
        )
        let knownEpics: [(key: String, title: String)] = workspace.tasks.compactMap { item in
            guard item.extended.issueKind == .epic else { return nil }
            let key = item.extended.binding(for: .jira)?.externalKey
                ?? CrossMeetingTaskReconciler.extractIssueKeys(from: item.text).first
            guard let key, !key.isEmpty else { return nil }
            return (key: key, title: item.text)
        }
        TaskDetailAndContextSheet(
            task: record,
            syncController: workspace.taskSync,
            knownEpics: knownEpics,
            onSave: { payload in
                await workspace.updateTaskExtendedDetails(
                    taskID: task.id,
                    payload: payload
                )
            },
            onDelete: {
                await workspace.deleteTask(task.id)
            },
            onOpenMeeting: onOpenSession
        )
    }
}
