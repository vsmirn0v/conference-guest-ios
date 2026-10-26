import AppKit

@MainActor final class NativeGuestJoinWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let invitation = NSTextField()
    private let name = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "Microphone and camera stay off until you enable them in the meeting.")
    private let join = NSButton(title: "Join meeting", target: nil, action: nil)
    var onJoin: ((NativeGuestJoinRequest) -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Rock'N'Roll for Mac"
        window.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Join a guest meeting")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        invitation.placeholderString = "HTTPS invitation URL"
        invitation.identifier = NSUserInterfaceItemIdentifier("nativeGuest.invitation")
        invitation.setAccessibilityLabel("Invitation URL")
        name.placeholderString = "Your name"
        name.stringValue = UserDefaults.standard.string(forKey: "nativeGuest.displayName") ?? NSFullUserName()
        name.identifier = NSUserInterfaceItemIdentifier("nativeGuest.displayName")
        name.setAccessibilityLabel("Display name")
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        join.bezelStyle = .rounded; join.target = self; join.action = #selector(joinMeeting)
        join.keyEquivalent = "\r"
        join.identifier = NSUserInterfaceItemIdentifier("nativeGuest.join")
        for view in [title, NSTextField(labelWithString: "Invitation URL"), invitation,
                     NSTextField(labelWithString: "Display name"), name, status, join] {
            stack.addArrangedSubview(view)
        }
        let content = window.contentView!; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            invitation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.initialFirstResponder = invitation
        window.center()
    }

    func show(completion: NativeGuestMeetingCompletion? = nil) {
        if let completion {
            status.stringValue = completion.message
            join.isEnabled = completion.permitsRejoin
            invitation.isEnabled = completion.permitsRejoin
            name.isEnabled = completion.permitsRejoin
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { window.orderOut(nil) }
    @objc private func joinMeeting() {
        guard join.isEnabled else { return }
        do {
            let request = try NativeGuestJoinRequest.parse(invitation: invitation.stringValue, displayName: name.stringValue)
            UserDefaults.standard.set(request.displayName, forKey: "nativeGuest.displayName")
            status.stringValue = "Microphone and camera stay off until you enable them in the meeting."
            onJoin?(request)
        } catch {
            status.stringValue = (error as? NativeGuestEntryError)?.message ?? "Could not read the invitation."
        }
    }
}
