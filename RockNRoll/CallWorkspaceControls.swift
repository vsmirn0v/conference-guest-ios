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
    @Published var routeName = "Audio output"

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
        presenter.present(sheet, animated: true)
    }
}
