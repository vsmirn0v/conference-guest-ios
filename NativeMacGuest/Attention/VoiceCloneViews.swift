import AppKit
import Combine
import SwiftUI

/// Settings → Intelligence → Voice, when replies speak in your cloned voice.
struct VoiceCloneSettingsView: View {
    @ObservedObject var clone: VoiceCloneStore
    @ObservedObject var listen: ListenModelStore
    var onPreparationAction: () -> Void = {}
    @State private var enrolling = false
    @State private var confirmingVoiceDeletion = false
    @State private var voiceDeletionError: String?

    var body: some View {
        Group {
            if let model = clone.model {
                setupProgress(model)
                modelRow(model)
                voiceRow
                Text(L("VoxCPM2 (OpenBMB, Apache-2.0) speaks in your voice from a short recording. It runs on this Mac's Neural Engine; the model and your voice never leave this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .sheet(isPresented: $enrolling) { VoiceEnrollmentView(clone: clone) }
            }
        }
        .onAppear { refreshStorage() }
        .confirmationDialog(L("Delete your saved voice?"), isPresented: $confirmingVoiceDeletion) {
            Button(L("Delete Saved Voice"), role: .destructive) {
                do { try clone.deleteVoice(); voiceDeletionError = nil }
                catch { voiceDeletionError = error.localizedDescription }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Your saved voice will be deleted from this Mac. The downloaded model will remain. You can record your voice again later."))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A user can free space in System Settings while this view stays open.
            refreshStorage()
        }
    }

    /// Downloading, preparing and enrolling are independent states: in
    /// particular a saved voice stays visible while model preparation fails.
    private func setupProgress(_ model: ListenModelCatalog.Model) -> some View {
        let modelStatus: String = {
            switch listen.state(model) {
            case .absent: return L("Not downloaded")
            case .downloading: return L("Downloading")
            case .installed: return L("Downloaded")
            case .failed: return L("Needs attention")
            }
        }()
        let preparationStatus: String = {
            switch clone.preparation {
            case .idle: return L("Not started")
            case .preparing: return L("Preparing")
            case .ready: return L("Ready")
            case .failed: return L("Needs attention")
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Voice setup")).font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    setupStep(L("Download model"), modelStatus)
                    setupStep(L("Prepare model"), preparationStatus)
                    setupStep(L("Your voice"), clone.stored == nil ? L("Not recorded") : L("Saved"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    setupStep(L("Download model"), modelStatus)
                    setupStep(L("Prepare model"), preparationStatus)
                    setupStep(L("Your voice"), clone.stored == nil ? L("Not recorded") : L("Saved"))
                }
            }
            if clone.installed && clone.stored == nil && clone.preparation != .ready {
                Text(L("You can record your voice while the model is preparing or needs repair."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupStep(_ title: String, _ state: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(state).font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func modelRow(_ model: ListenModelCatalog.Model) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)
        switch listen.state(model) {
        case .absent:
            HStack {
                Text(L("Voice model, %@", size))
                Spacer()
                Button(L("Download")) { clone.download() }
            }
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress) { Text(L("Downloading the voice model…")).font(.caption) }
                Button(L("Cancel")) { clone.cancelDownload() }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                if let storage = listen.storageFailure(model) {
                    Label(L("Not enough disk space to download the voice model."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    storageDetails(storage)
                    storageActions { clone.download() }
                } else {
                    Label(L("The voice model could not be downloaded."), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(L("Try again. If the problem continues, collect diagnostics."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Try Again")) { clone.download() }
                }
            }
        case .installed:
            HStack(alignment: .firstTextBaseline) {
                preparationStatus
                Spacer()
                Button(L("Delete Model"), role: .destructive) { clone.deleteModel() }.buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private var preparationStatus: some View {
        switch clone.preparation {
        case .idle:
            Button(L("Prepare for the Neural Engine")) { retryPreparation() }
        case .preparing:
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Preparing for this Mac's Neural Engine…"))
                    Text(L("The voice worker specializes the model and checks that it can synthesize speech. This can take several minutes."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let started = clone.preparingSince {
                        Text(started, style: .timer).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        case .ready:
            Label(L("Voice model ready on the Neural Engine"), systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed:
            preparationFailure
        }
    }

    @ViewBuilder private var preparationFailure: some View {
        let failure = clone.failure
        VStack(alignment: .leading, spacing: 6) {
            switch failure?.kind {
            case .storage:
                Label(L("Not enough disk space to prepare the voice model."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if let storage = failure?.storage { storageDetails(storage) }
                else { Text(L("macOS did not report how much more space is needed.")).font(.caption).foregroundStyle(.secondary) }
                storageActions { retryPreparation() }
            case .rateLimited:
                Label(L("The voice model has been tried too many times."), systemImage: "clock")
                    .foregroundStyle(.orange)
                if let retryAfter = failure?.retryAfter {
                    Text(failure?.rateLimitedRepair == true
                         ? L("Repair available after %@.", retryAfter.formatted(date: .abbreviated, time: .shortened))
                         : L("Try again after %@.", retryAfter.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Try again later.")).font(.caption).foregroundStyle(.secondary)
                }
                if failure?.repairAvailable == true {
                    Text(L("The cause is not clear. Repairing the cached model may help. Your downloaded model and saved voice will be kept."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    if failure?.repairAvailable == true {
                        Button(L("Repair Voice Model")) { onPreparationAction(); clone.repair() }
                            .accessibilityIdentifier("voiceModel.repair")
                            .disabled(failure?.rateLimitedRepair == true && (failure?.retryAfter.map { $0 > context.date } ?? false))
                    }
                    Button(L("Try Again")) { retryPreparation() }
                        .disabled(failure?.rateLimitedRepair != true && (failure?.retryAfter.map { $0 > context.date } ?? false))
                }
            case .busy:
                Label(L("The voice model is being used by another process."), systemImage: "clock")
                    .foregroundStyle(.orange)
                Text(L("Try again when the other operation finishes.")).font(.caption).foregroundStyle(.secondary)
                repairActionIfAvailable(failure)
                Button(L("Try Again")) { retryPreparation() }
            case .interrupted:
                Label(L("Voice model preparation was interrupted."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                repairActionIfAvailable(failure)
                Button(L("Try Again")) { retryPreparation() }
            case .cache, .unknown, nil:
                Label(L("The voice model could not start."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if failure?.repairAvailable == true {
                    Text(L("The cause is not clear. Repairing the cached model may help. Your downloaded model and saved voice will be kept."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("Repair Voice Model")) { onPreparationAction(); clone.repair() }
                            .accessibilityIdentifier("voiceModel.repair")
                        Button(L("Try Again")) { retryPreparation() }
                    }
                } else {
                    Text(L("The cause is not clear. Try again; if the problem continues, collect diagnostics."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L("Try Again")) { retryPreparation() }
                }
            }
            if let date = failure?.failedAt {
                Text(L("Last attempt: %@", date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("voiceModel.preparationFailure")
    }

    @ViewBuilder private func repairActionIfAvailable(_ failure: ClonedVoiceFailure?) -> some View {
        if failure?.repairAvailable == true {
            Text(L("The cause is not clear. Repairing the cached model may help. Your downloaded model and saved voice will be kept."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L("Repair Voice Model")) { onPreparationAction(); clone.repair() }
                .accessibilityIdentifier("voiceModel.repair")
        }
    }

    /// The requirement is an estimate for the relevant operation, never a guess
    /// based on the downloaded model's size when Core AI cannot report a need.
    @ViewBuilder private func storageDetails(_ storage: VoiceStorageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let available = storage.availableBytes, available >= 0 {
                let amount = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                switch storage.location {
                case .model: Text(L("Available on the model disk: %@.", amount))
                case .temporary: Text(L("Available for temporary downloads: %@.", amount))
                case nil: Text(L("Available disk space: %@.", amount))
                }
                if let required = storage.requiredBytes, required >= 0 {
                    let needed = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
                    if required > available {
                        let shortfall = ByteCountFormatter.string(fromByteCount: required - available, countStyle: .file)
                        Text(L("Estimated minimum space needed: %@. Free at least %@; additional working space may be needed.", needed, shortfall))
                    } else {
                        Text(L("Estimated minimum space needed: %@. Additional working space may be needed.", needed))
                    }
                } else {
                    Text(L("macOS did not report how much more space is needed."))
                }
            } else {
                if let required = storage.requiredBytes, required >= 0 {
                    Text(L("Estimated minimum space needed: %@. Additional working space may be needed.", ByteCountFormatter.string(fromByteCount: required, countStyle: .file)))
                }
                Text(L("The available space could not be checked. Open Storage Settings and try again."))
            }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func storageActions(_ retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(L("Open Storage Settings")) { openStorageSettings() }
                    .accessibilityIdentifier("voiceModel.openStorage")
                Button(L("Check Again")) { refreshStorage(); retry() }
                    .accessibilityIdentifier("voiceModel.checkStorage")
            }
            Text(L("System Settings → General → Storage"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshStorage() {
        clone.refreshStorage()
        if let model = clone.model { listen.refreshStorageFailure(model) }
    }

    private func retryPreparation() {
        onPreparationAction()
        clone.prepare()
    }

    private func openStorageSettings() {
        let settings = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        if !NSWorkspace.shared.open(settings) {
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    @ViewBuilder private var voiceRow: some View {
        if let stored = clone.stored {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Your saved voice"))
                        Text(L("%ld-second sample, recorded %@", Int(stored.seconds.rounded()),
                               stored.recordedAt.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Record Again…")) { enrolling = true }.disabled(!clone.installed)
                    Button(L("Delete Saved Voice…"), role: .destructive) { confirmingVoiceDeletion = true }.buttonStyle(.borderless)
                }
                if let voiceDeletionError {
                    Label(L("Could not delete your saved voice: %@", voiceDeletionError), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack {
                Text(clone.installed ? L("Record a short sample of your voice.") : L("After the download, record a short sample of your voice."))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Record Your Voice…")) { enrolling = true }.disabled(!clone.installed)
            }
        }
    }
}

/// Records (or opens) a sample of your voice reading a known text and saves its features.
struct VoiceEnrollmentView: View {
    @ObservedObject var clone: VoiceCloneStore
    @StateObject private var recorder = VoiceSampleRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var transcript = L("Hello! This is a sample of my voice for replies in meetings. I speak calmly and clearly, at my usual pace. Today we are going over the plans for the week: the release, the certificates and the database migration.")
    @State private var chosenFile: URL?
    @State private var saving = false
    @State private var error: String?

    private var source: URL? { chosenFile ?? recorder.file }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Record Your Voice")).font(.title2.weight(.semibold))
            Text(L("In a quiet room, read the text below aloud in the voice you use in meetings. 10 to 20 seconds is enough. Only the model's features of the recording are kept, on this Mac."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $transcript).font(.body).frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Text(L("If you say it differently, change the text to match: the model learns from the recording and its words together."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(recorder.recording ? L("Stop") : L("Record")) { toggleRecording() }
                    .keyboardShortcut(.defaultAction).disabled(saving)
                if recorder.recording {
                    ProgressView(value: Double(min(1, recorder.level))).frame(width: 120)
                }
                if recorder.recording || recorder.file != nil {
                    Text(L("%.0f s", recorder.seconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let chosenFile { Text(chosenFile.lastPathComponent).lineLimit(1).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Open a Recording…")) { chooseFile() }.disabled(recorder.recording || saving)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(L("Cancel")) { recorder.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? L("Saving…") : L("Use This Recording")) { save() }
                    .disabled(source == nil || recorder.recording || saving || transcript.trimmed.isEmpty)
            }
        }.padding(20).frame(width: 540)
    }

    private func toggleRecording() {
        error = nil
        if recorder.recording { recorder.stop(); return }
        chosenFile = nil
        Task { @MainActor in
            do { try await recorder.start() } catch { self.error = error.localizedDescription }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenFile = url
        error = nil
    }

    private func save() {
        guard let source else { return }
        saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await clone.saveVoice(from: source, transcript: transcript)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
