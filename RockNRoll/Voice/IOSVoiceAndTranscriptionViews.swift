import AVFoundation
import ConferenceCore
import SwiftUI
import UniformTypeIdentifiers

struct VoiceReplyTargetRoom: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isTalk: Bool
    let isCurrent: Bool
}

struct VoiceReplySheetView: View {
    let targets: [VoiceReplyTargetRoom]
    @State private var selectedTargetID: UUID
    let onSpeak: (UUID, String) async throws -> Void
    let onStop: (UUID) -> Void

    @ObservedObject var voiceStore: IOSVoiceStore
    @ObservedObject var modelStore: IOSListenModelStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isSpeaking = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private static let presets: [String] = [
        "One moment, I'll unmute shortly.",
        "Sounds good, thank you.",
        "Could you repeat that, please?",
        "Yes, I can hear and see the screen."
    ]

    init(
        targets: [VoiceReplyTargetRoom],
        initialTargetID: UUID?,
        voiceStore: IOSVoiceStore = .shared,
        modelStore: IOSListenModelStore = .shared,
        onSpeak: @escaping (UUID, String) async throws -> Void,
        onStop: @escaping (UUID) -> Void
    ) {
        self.targets = targets
        let fallbackID = initialTargetID
            ?? targets.first(where: \.isCurrent)?.id
            ?? targets.first?.id
            ?? UUID()
        self._selectedTargetID = State(initialValue: fallbackID)
        self.voiceStore = voiceStore
        self.modelStore = modelStore
        self.onSpeak = onSpeak
        self.onStop = onStop
    }

    var body: some View {
        NavigationStack {
            Form {
                if targets.count > 1 {
                    Section(L("Target room")) {
                        Picker(L("Speak in"), selection: $selectedTargetID) {
                            ForEach(targets) { target in
                                Text("\(target.title) (\(target.isTalk ? L("Talk") : L("Listening")))")
                                    .tag(target.id)
                            }
                        }
                    }
                } else if let single = targets.first {
                    Section {
                        LabeledContent(
                            L("Room"),
                            value: "\(single.title) (\(single.isTalk ? L("Talk") : L("Listening")))"
                        )
                    }
                }

                Section(L("Message to speak")) {
                    TextField(L("Type what to speak into the meeting…"), text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("voice-reply.input")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.presets, id: \.self) { key in
                                let localized = L(key)
                                Button(localized) {
                                    text = localized
                                }
                                .buttonStyle(.bordered)
                                .font(.footnote)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    if isSpeaking {
                        Button(role: .destructive) {
                            onStop(selectedTargetID)
                            isSpeaking = false
                        } label: {
                            Label(L("Stop speaking"), systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("voice-reply.stop")
                    } else {
                        Button {
                            speak()
                        } label: {
                            Label(L("Speak in room"), systemImage: "waveform.and.mic")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || targets.isEmpty)
                        .accessibilityIdentifier("voice-reply.send")
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(L("Sends your typed reply as speech into the selected room. Your microphone stays muted."))
                }

                Section {
                    NavigationLink {
                        TranscriptionAndVoiceSettingsView(
                            modelStore: modelStore,
                            voiceStore: voiceStore
                        )
                    } label: {
                        LabeledContent(L("Voice"), value: voiceStore.engine.title)
                    }
                }
            }
            .navigationTitle(L("Voice reply"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
            }
        }
    }

    private func speak() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        errorMessage = nil
        statusMessage = L("Synthesizing and speaking…")
        isSpeaking = true
        let targetID = selectedTargetID
        Task { @MainActor in
            defer { isSpeaking = false }
            do {
                try await onSpeak(targetID, message)
                statusMessage = L("Voice reply sent.")
            } catch is CancellationError {
                statusMessage = L("Stopped.")
            } catch {
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct TranscriptionAndVoiceSettingsView: View {
    @ObservedObject var modelStore: IOSListenModelStore
    @ObservedObject var voiceStore: IOSVoiceStore
    @ObservedObject var voxStore: IOSVoxCPM2Store
    @ObservedObject private var previewPlayer = IOSVoicePreviewPlayer.shared
    var onDone: (() -> Void)?

    @State private var previewError: String?
    @State private var isGeneratingPreview = false
    @State private var isGeneratingAuditionPreview = false
    @State private var auditionPreviewError: String?
    @State private var showingEnrollmentSheet = false
    @State private var confirmingDeleteVoxModel = false
    @State private var confirmingDeleteVoxVoice = false

    init(
        modelStore: IOSListenModelStore = .shared,
        voiceStore: IOSVoiceStore = .shared,
        voxStore: IOSVoxCPM2Store = .shared,
        onDone: (() -> Void)? = nil
    ) {
        self.modelStore = modelStore
        self.voiceStore = voiceStore
        self.voxStore = voxStore
        self.onDone = onDone
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Speech model"), selection: $modelStore.selectedModel) {
                    ForEach(IOSListenModel.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                Text(modelStore.selectedModel.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker(L("Spoken language"), selection: $modelStore.language) {
                    ForEach(IOSTranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }

                Toggle(L("Start automatically when joining"), isOn: $modelStore.autoStartLocalTranscription)
            } header: {
                Text(L("On-device transcription"))
            } footer: {
                Text(L("Processes meeting audio in memory on this iPhone without sending audio to external transcription servers."))
            }

            Section(L("GigaAM v3 (Offline CoreML)")) {
                switch modelStore.gigaamState {
                case .notInstalled:
                    Button {
                        modelStore.downloadGigaAM()
                    } label: {
                        Label(L("Download GigaAM v3 (~425 MB)"), systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("transcription.download-gigaam")
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress)
                        HStack {
                            Text(L("Downloading… %ld%%", Int((progress * 100).rounded())))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Cancel")) {
                                modelStore.cancelDownload()
                            }
                            .font(.footnote)
                        }
                    }
                case .installed:
                    HStack {
                        Label(L("Installed and verified"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(L("Delete"), role: .destructive) {
                            modelStore.deleteGigaAM()
                        }
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button {
                            modelStore.downloadGigaAM()
                        } label: {
                            Label(L("Try again"), systemImage: "arrow.clockwise")
                        }
                    }
                }
            }

            Section {
                Picker(L("Voice engine"), selection: $voiceStore.engine) {
                    ForEach(IOSVoiceEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }

                switch voiceStore.engine {
                case .system:
                    Picker(L("System voice"), selection: $voiceStore.systemVoiceIdentifier) {
                        Text(L("Automatic for language")).tag("")
                        ForEach(IOSVoiceStore.availableSystemVoices(), id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                case .personal:
                    Text(L("Uses the Personal Voice created on your iPhone in Settings → Accessibility → Personal Voice."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .voxCPM2:
                    if !voxStore.isDeviceSupported {
                        Label(voxStore.unsupportedReason, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if !voxStore.installState.isInstalled {
                        Text(L("Download the VoxCPM2 neural model below (~2.3 GB) to generate speech or clone your voice offline on this iPhone."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if voxStore.useClonedVoice && voxStore.storedVoice == nil {
                        Text(L("Record a short sample below to speak in your cloned voice, or turn off Use my cloned voice for zero-shot speech."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(voxStore.useClonedVoice && voxStore.storedVoice != nil
                            ? L("Using your saved VoxCPM2 cloned voice on-device.")
                            : L("Using VoxCPM2 zero-shot neural voice on-device."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .rapidMLX:
                    TextField(L("Server URL (e.g. http://mac.local:8080/v1)"), text: $voiceStore.rapidMLXBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Model"), text: $voiceStore.rapidMLXModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L("Voice style notes (optional)"), text: $voiceStore.rapidMLXDescription)
                    if let endpoint = voiceStore.rapidMLXEndpoint {
                        Text(L("For previews and meeting replies, including assistant replies, Rapid-MLX sends the text, language, model name and voice style notes to %@ to generate speech.", endpoint.absoluteString))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Toggle(L("Allow speech requests to this server"), isOn: Binding(
                            get: { voiceStore.hasRapidMLXConsent },
                            set: { voiceStore.setRapidMLXConsent($0) }
                        ))
                        .accessibilityIdentifier("voice.rapidmlx.consent")
                    } else {
                        Text(L("Enter an HTTP or HTTPS server address without credentials, a query or a fragment."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if previewPlayer.isPlaying {
                    Button(role: .destructive) {
                        previewPlayer.stop()
                    } label: {
                        Label(L("Stop preview"), systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        runPreview()
                    } label: {
                        if isGeneratingPreview {
                            Label(L("Generating preview…"), systemImage: "hourglass")
                        } else {
                            Label(L("Preview voice"), systemImage: "play.circle")
                        }
                    }
                    .disabled(isGeneratingPreview || (voiceStore.engine == .rapidMLX && !voiceStore.hasRapidMLXConsent))
                    .accessibilityIdentifier("voice.preview")
                }

                if let previewError {
                    Text(previewError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(L("Voice generation"))
            } footer: {
                Text(L("Used when sending Voice replies in both talk and listening rooms."))
            }

            assistantAuditionSection

            voxCPM2Section
        }
        .navigationTitle(L("Transcription & voice"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done"), action: onDone)
                }
            }
        }
        .sheet(isPresented: $showingEnrollmentSheet) {
            IOSVoiceEnrollmentSheet(voxStore: voxStore)
        }
        .confirmationDialog(
            L("Delete VoxCPM2 model?"),
            isPresented: $confirmingDeleteVoxModel,
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                voxStore.deleteModel(voiceStore: voiceStore)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Removes the downloaded 2.3 GB VoxCPM2 weights. Any saved voice sample features are kept."))
        }
        .confirmationDialog(
            L("Delete saved voice?"),
            isPresented: $confirmingDeleteVoxVoice,
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                voxStore.deleteSavedVoice()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Deletes your saved voice prompt features from this iPhone. The VoxCPM2 model stays installed."))
        }
    }

    @ViewBuilder
    private var assistantAuditionSection: some View {
        Section {
            Toggle(L("Hands-free “Rock” wake word"), isOn: $voiceStore.wakeWordEnabled)
                .accessibilityIdentifier("voice.wakeWord")
            Picker(L("Assistant reply voice"), selection: $voiceStore.assistantAuditionVoice) {
                Section(L("Neural presets (VoxCPM2)")) {
                    ForEach(AssistantVoxVoicePreset.allCases) { preset in
                        Text(preset.localizedTitle).tag(AssistantAuditionVoiceSelection.voxPreset(preset))
                    }
                }
                Section(L("Personal & Cloned")) {
                    if voxStore.isDeviceSupported {
                        Text(L("My cloned voice")).tag(AssistantAuditionVoiceSelection.clonedVoice)
                    }
                    Text(L("Personal Voice")).tag(AssistantAuditionVoiceSelection.personalVoice)
                }
                Section(L("iPhone system voices")) {
                    Text(L("System voice (automatic)")).tag(AssistantAuditionVoiceSelection.systemVoice(identifier: ""))
                    ForEach(IOSVoiceStore.availableSystemVoices().prefix(12), id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(AssistantAuditionVoiceSelection.systemVoice(identifier: voice.identifier))
                    }
                }
            }
            if case .voxPreset(let preset) = voiceStore.assistantAuditionVoice {
                Text(preset.localizedSubtitle + " " + L("Uses VoxCPM2 when downloaded, or falls back to the iPhone system voice."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if voiceStore.assistantAuditionVoice == .clonedVoice && voxStore.storedVoice == nil {
                Text(L("Record a sample below to use your cloned voice, or answers will use the iPhone system voice."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle(L("Speak voice-triggered replies aloud"), isOn: $voiceStore.autoAuditionVoiceReplies)
            Toggle(L("Speak typed replies aloud"), isOn: $voiceStore.autoAuditionTypedReplies)
            if previewPlayer.isPlaying {
                Button(role: .destructive) {
                    previewPlayer.stop()
                } label: {
                    Label(L("Stop preview"), systemImage: "stop.circle")
                }
            } else {
                Button {
                    runAuditionPreview()
                } label: {
                    if isGeneratingAuditionPreview {
                        Label(L("Preparing…"), systemImage: "hourglass")
                    } else {
                        Label(L("Preview assistant voice"), systemImage: "play.circle")
                    }
                }
                .disabled(isGeneratingAuditionPreview)
            }
            if let auditionPreviewError {
                Text(auditionPreviewError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(L("Assistant reply voice"))
        } footer: {
            Text(L("Say “Rock, …” or “Рок, …” to activate Assistant anywhere in the app or while muted in a call."))
        }
    }

    private func runAuditionPreview() {
        auditionPreviewError = nil
        isGeneratingAuditionPreview = true
        Task { @MainActor in
            defer { isGeneratingAuditionPreview = false }
            do {
                let buffer = try await voiceStore.synthesizeAssistantResponse(L("Hello! This is how Assistant answers sound on your iPhone."))
                try previewPlayer.play(buffer)
            } catch is CancellationError {
                return
            } catch {
                auditionPreviewError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var voxCPM2Section: some View {
        Section {
            if !voxStore.isDeviceSupported {
                Label(voxStore.unsupportedReason, systemImage: "cpu")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                switch voxStore.installState {
                case .notInstalled:
                    Button {
                        voxStore.downloadModel()
                    } label: {
                        Label(L("Download VoxCPM2 (~2.3 GB)"), systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("voice.download-voxcpm2")
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress)
                        HStack {
                            Text(L("Downloading… %ld%%", Int((progress * 100).rounded())))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Cancel")) {
                                voxStore.cancelDownload()
                            }
                            .font(.footnote)
                        }
                    }
                case .installed:
                    HStack {
                        Label(L("Installed and verified"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(L("Delete"), role: .destructive) {
                            confirmingDeleteVoxModel = true
                        }
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button {
                            voxStore.downloadModel()
                        } label: {
                            Label(L("Try again"), systemImage: "arrow.clockwise")
                        }
                    }
                }

                Toggle(L("Use my cloned voice"), isOn: $voxStore.useClonedVoice)

                if let saved = voxStore.storedVoice {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(
                            L("Saved voice"),
                            value: L("%ld s · %@", max(1, Int(saved.seconds.rounded())),
                                     saved.recordedAt.formatted(date: .abbreviated, time: .shortened))
                        )
                        HStack {
                            Button(L("Re-record")) {
                                showingEnrollmentSheet = true
                            }
                            .disabled(!voxStore.installState.isInstalled || voxStore.isWorking)
                            Spacer()
                            Button(L("Delete saved voice"), role: .destructive) {
                                confirmingDeleteVoxVoice = true
                            }
                        }
                        .font(.footnote)
                    }
                } else {
                    Button {
                        showingEnrollmentSheet = true
                    } label: {
                        Label(L("Record or import your voice…"), systemImage: "mic.badge.plus")
                    }
                    .disabled(!voxStore.installState.isInstalled || voxStore.isWorking)
                    .accessibilityIdentifier("voice.enroll-voxcpm2")
                }
            }
        } header: {
            Text(L("VoxCPM2 (On-Device Neural Voice)"))
        } footer: {
            Text(L("Runs VoxCPM2 4-bit on Metal GPU on 8 GB+ iPhones across 30 languages. Only encoded acoustic features are kept on this iPhone, not the raw recording."))
        }
    }

    private func runPreview() {
        previewError = nil
        isGeneratingPreview = true
        let sample = L("Hello everyone, this is a voice reply check from Rock'N'Roll.")
        Task { @MainActor in
            defer { isGeneratingPreview = false }
            do {
                let buffer = try await voiceStore.synthesize(sample)
                try previewPlayer.play(buffer)
            } catch {
                previewError = error.localizedDescription
            }
        }
    }
}

struct IOSVoiceEnrollmentSheet: View {
    @ObservedObject var voxStore: IOSVoxCPM2Store
    @StateObject private var recorder = IOSVoiceSampleRecorder()
    @Environment(\.dismiss) private var dismiss

    @State private var transcript = L("Hello! This is a sample of my voice for replies in meetings. I speak calmly and clearly at my usual pace.")
    @State private var importedTempFile: URL?
    @State private var importedFileName: String?
    @State private var showingImporter = false
    @State private var saving = false
    @State private var errorMessage: String?

    private var activeSourceURL: URL? {
        importedTempFile ?? recorder.file
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Reference phrase spoken in the recording"), text: $transcript, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text(L("Words spoken in sample"))
                } footer: {
                    Text(L("Read these words aloud calmly for 4 to 20 seconds outside an active call. Update the text if you say something different."))
                }

                Section(L("Voice sample")) {
                    HStack(spacing: 12) {
                        Button {
                            toggleRecording()
                        } label: {
                            Label(
                                recorder.recording ? L("Stop recording") : L("Record voice"),
                                systemImage: recorder.recording ? "stop.circle.fill" : "mic.circle.fill"
                            )
                        }
                        .tint(recorder.recording ? .red : .accentColor)
                        .disabled(saving)

                        Spacer()

                        if recorder.recording || recorder.file != nil {
                            Text(L("%ld s", Int(recorder.seconds.rounded(.down))))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    if recorder.recording {
                        ProgressView(value: Double(min(1, max(0, recorder.level))))
                    }

                    Button {
                        showingImporter = true
                    } label: {
                        Label(
                            importedFileName ?? L("Import audio file…"),
                            systemImage: "folder"
                        )
                    }
                    .disabled(recorder.recording || saving)
                }

                Section {
                    Button {
                        saveVoice()
                    } label: {
                        if saving {
                            Label(L("Encoding cloned voice…"), systemImage: "hourglass")
                                .frame(maxWidth: .infinity)
                        } else {
                            Label(L("Save cloned voice"), systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(
                        activeSourceURL == nil
                            || recorder.recording
                            || saving
                            || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("voice.save-enrollment")

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L("Clone your voice"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) {
                        recorder.stop()
                        cleanupImportedTempFile()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
                handleImportResult(result)
            }
            .onDisappear {
                recorder.stop()
                cleanupImportedTempFile()
            }
        }
    }

    private func toggleRecording() {
        errorMessage = nil
        if recorder.recording {
            recorder.stop()
            return
        }
        cleanupImportedTempFile()
        importedFileName = nil
        Task { @MainActor in
            do {
                try await recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        errorMessage = nil
        switch result {
        case .success(let pickedURL):
            let accessed = pickedURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { pickedURL.stopAccessingSecurityScopedResource() }
            }
            cleanupImportedTempFile()
            let ext = pickedURL.pathExtension.isEmpty ? "wav" : pickedURL.pathExtension
            let copyURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ios-voice-import-\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.copyItem(at: pickedURL, to: copyURL)
                importedTempFile = copyURL
                importedFileName = pickedURL.lastPathComponent
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func saveVoice() {
        guard let sourceURL = activeSourceURL else { return }
        errorMessage = nil
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await voxStore.enrollVoice(from: sourceURL, transcript: transcript)
                cleanupImportedTempFile()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cleanupImportedTempFile() {
        if let url = importedTempFile {
            try? FileManager.default.removeItem(at: url)
            importedTempFile = nil
        }
    }
}
