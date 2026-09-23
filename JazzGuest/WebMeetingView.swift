import SwiftUI
import WebKit

struct WebMeeting: Identifiable {
    let id = UUID()
    let url: URL
}

struct WebMeetingView: View {
    let meeting: WebMeeting
    @ObservedObject var model: ConferenceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Jazz guest meeting")
                    .font(.headline)
                Spacer()
                Button("Close call", role: .destructive) { model.leave() }
            }
            .padding()
            JazzGuestWebView(url: meeting.url)
        }
        .confirmationDialog(
            "Close the current meeting and prepare the new invitation?",
            isPresented: $model.showSwitchConfirmation
        ) {
            Button("Close current meeting") { model.replaceWithPending() }
            Button("Stay here", role: .cancel) {}
        }
    }
}

private struct JazzGuestWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}
