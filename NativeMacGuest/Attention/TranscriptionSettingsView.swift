import SwiftUI

/// Settings → Transcription: transcribe meetings on this Mac, and the models to do it with.
struct NativeDesktopTranscriptionSettings: View {
    @ObservedObject var store: ListenModelStore
    /// Readiness and memory of the on-device models. Nil when the settings
    /// view is built without an Attention coordinator (previews, tests).
    var models: LocalModelStatusStore? = nil

    var body: some View {
        Form {
            Section {
                Toggle(L("Transcribe meetings on this Mac"), isOn: $store.enabled)
                    .accessibilityIdentifier("transcription.local.enabled")
                Text(L("When a meeting is not transcribed by its service, other participants' speech is turned into text here, for Live text and Catch up. It keeps working while the meeting's sound is off."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.enabled, !store.ready {
                    Label(store.selected.map { store.state($0).installed } == true
                          ? L("Downloading the voice detector…") : L("Download a speech model below to start."), systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle(L("Include my microphone"), isOn: $store.includesMicrophone).disabled(!store.enabled)
                    .accessibilityIdentifier("transcription.local.microphone")
                Text(L("What you say joins the transcript of the meeting that holds your microphone, while it is unmuted. Nothing is transcribed while you are muted."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Meetings to transcribe")) {
                Toggle(L("Telemost and TrueConf"), isOn: $store.transcribesExternal).disabled(!store.enabled)
                    .accessibilityIdentifier("transcription.local.external")
                Text(L("These services send everyone's voice as one stream. Names come from who the service shows as speaking; TrueConf does not report it, so its lines show “Participant”."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(L("Rock jam sessions"), isOn: $store.transcribesRock).disabled(!store.enabled)
                    .accessibilityIdentifier("transcription.local.rock")
                Text(L("Off by default: jam sessions are mostly music. Each musician is transcribed separately."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Speech model")) {
                ForEach(store.catalog.listen) { model in row(model) }
                Text(L("Models run on this Mac, on its processor or Neural Engine. They are downloaded from Hugging Face, checked against a fixed checksum, and stored in this app's folder."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let models {
                Section(L("On-device models")) {
                    LocalModelStatusIndicator(models: models)
                    Text(L("Readiness and memory of the speech and voice models that run on this Mac. A model can be ready while not loaded; it loads when a meeting needs it."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("Privacy")) {
                Label(L("Audio is processed in memory and never recorded or sent anywhere."), systemImage: "lock")
                Label(L("The app does not tell other participants. Let them know if your organisation requires it."), systemImage: "person.2")
                Label(L("Your microphone is transcribed only while you are unmuted in a meeting."), systemImage: "mic")
            }.font(.callout)
        }.formStyle(.grouped)
            .onAppear { store.refresh() }
    }

    @ViewBuilder private func row(_ model: ListenModelCatalog.Model) -> some View {
        let state = store.state(model), chosen = store.selectedID == model.id
        HStack(alignment: .top, spacing: 10) {
            Button { store.selectedID = model.id } label: {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle").foregroundStyle(chosen ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).accessibilityLabel(L("Use %@", model.title))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.title).font(.body.weight(chosen ? .semibold : .regular))
                    if model.id == ListenModelStore.defaultModel { Text(L("Recommended")).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Color.green.opacity(0.18), in: Capsule()) }
                }
                Text(detail(model)).font(.caption).foregroundStyle(.secondary)
                switch state {
                case .downloading(let progress):
                    ProgressView(value: progress).frame(maxWidth: 240)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                default: EmptyView()
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .installed:
                Button(L("Delete")) { store.delete(model) }.buttonStyle(.borderless).foregroundStyle(.red)
            case .downloading:
                Button(L("Cancel")) { store.cancel(model) }.buttonStyle(.borderless)
            case .absent, .failed:
                Button(L("Download")) { store.selectedID = model.id; store.download(model) }
            }
        }.padding(.vertical, 2).contentShape(Rectangle())
    }

    private func detail(_ model: ListenModelCatalog.Model) -> String {
        let languages = model.languages == ["*"] ? L("99 languages") : model.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", ")
        let size = ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)
        let note: String
        switch model.id {
        case "gigaam-v3-rnnt-punct": note = L("Russian, with punctuation; runs on the processor")
        case "gigaam-v3-e2e-ctc": note = L("Russian, with punctuation")
        case "gigaam-v3-e2e-rnnt-coreml": note = L("Runs on the Neural Engine: barely uses the processor. First start takes a few seconds")
        case "whisper-large-v3-turbo": note = L("Mixed languages; about 15 times slower")
        default: note = ""
        }
        return [languages, size, model.licence, note].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
