import Combine
import Foundation
import UIKit

/// Shared actions and visible media state for the call and its conversation view.
@MainActor
final class CallWorkspaceControls: ObservableObject {
    @Published var microphoneOn = false
    @Published var cameraOn = false
    @Published var onHold = false
    @Published var speakerOn = true
    @Published var routeName = L("Audio output")

    var invitationURL: URL?
    var roomIdentifier: String?
    var toggleMicrophone: (() -> Void)?
    var toggleCamera: (() -> Void)?
    var toggleSpeaker: (() -> Void)?
    var leave: (() -> Void)?

    func copyInvitation() {
        guard let invitationURL else { return }
        UIPasteboard.general.url = invitationURL
    }

    func shareInvitation(from view: UIView) {
        guard let invitationURL else { return }
        var responder: UIResponder? = view
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard let presenter = responder as? UIViewController else { return }
        let sheet = UIActivityViewController(activityItems: [invitationURL], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController { popover.sourceView = view }
        presenter.present(sheet, animated: true) { [weak sheet] in
            sheet?.view.accessibilityIdentifier = "Invitation sharing"
        }
    }

    func showDetails(from view: UIView, presenter: UIViewController?, title: String, lines: [String]) {
        guard let presenter, presenter.presentedViewController == nil else { return }
        let sheet = UIAlertController(title: title, message: lines.filter { !$0.isEmpty }.joined(separator: "\n"),
                                      preferredStyle: .actionSheet)
        if invitationURL != nil {
            sheet.addAction(UIAlertAction(title: L("Invite musicians"), style: .default) { [weak self, weak view, weak sheet] _ in
                // Present the system share sheet after the details sheet has finished closing.
                sheet?.dismiss(animated: true) { [weak self, weak view] in
                    if let view { self?.shareInvitation(from: view) }
                }
            })
            sheet.addAction(UIAlertAction(title: L("Copy link"), style: .default) { [weak self] _ in self?.copyInvitation() })
        }
        sheet.addAction(UIAlertAction(title: L("Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = view.bounds
        presenter.present(sheet, animated: true)
    }
}
