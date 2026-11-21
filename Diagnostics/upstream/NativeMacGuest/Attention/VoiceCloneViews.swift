import AppKit
import SwiftUI

/// Settings → Intelligence → Voice, when replies speak in your cloned voice.
struct VoiceCloneSettingsView: View {
    @ObservedObject var clone: VoiceCloneStore
    @ObservedObject var listen: ListenModelStore
    @State private var enrolling = false

    var body: some View {
        if let model = clone.model {
            modelRow(model)
            voiceRow
            Text(L("VoxCPM2 (OpenBMB, Apache-2.0) speaks in your voice from a short recording. It runs on this Mac's Neural Engine; the model and your voice never leave this Mac."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .sheet(isPresented: $enrolling) { VoiceEnrollmentView(clone: clone) }
        }
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
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button(L("Try Again")) { clone.download() }
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
            Button(L("Prepare for the Neural Engine")) { clone.prepare() }
        case .preparing:
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Preparing for this Mac's Neural Engine…"))
                    Text(L("This happens once after a download or an update and can take half an hour. You can keep working; meetings are not affected."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready:
            Label(L("Voice model ready on the Neural Engine"), systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Button(L("Try Again")) { clone.prepare() }
            }
        }
    }

    @ViewBuilder private var voiceRow: some View {
        if let stored = clone.stored {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Your voice"))
                    Text(L("%ld-second sample, recorded %@", Int(stored.seconds.rounded()),
                           stored.recordedAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Record Again…")) { enrolling = true }.disabled(!clone.installed)
                Button(L("Delete"), role: .destructive) { clone.deleteVoice() }.buttonStyle(.borderless)
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
