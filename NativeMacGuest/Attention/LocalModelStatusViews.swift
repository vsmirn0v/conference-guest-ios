import SwiftUI

/// Compact chip in the Assistant toolbar and in Settings → Assistant.
/// Tapping opens the memory/residency detail popover.
struct LocalModelStatusIndicator: View {
    @ObservedObject var models: LocalModelStatusStore
    /// Opens Settings → Transcription. Nil in Settings itself.
    var onOpenTranscription: (() -> Void)?
    /// Opens Settings → Assistant → Voice. Nil in Settings itself.
    var onOpenVoice: (() -> Void)?
    @State private var showingPopover = false

    private var readinessColor: Color {
        // The chip color follows the least ready applicable model.
        let statuses = [models.speechStatus, models.voiceStatus]
        if statuses.contains(where: { if case .failed = $0.readiness { return true }; return false }) { return .red }
        if statuses.contains(where: {
            switch $0.readiness {
            case .downloading, .preparationNeeded, .preparing, .loading, .notInstalled, .setupNeeded: return true
            default: return false
            }
        }) { return .orange }
        if statuses.contains(where: { $0.readiness == .ready }) { return .teal }
        return .secondary
    }

    var body: some View {
        Button { showingPopover = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "laptopcomputer")
                Text(models.overallSummary)
                if models.speechStatus.readiness == .ready || models.voiceStatus.readiness == .ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(readinessColor)
            .overlay(Capsule().stroke(readinessColor.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover) {
            LocalModelStatusPopover(models: models, onOpenTranscription: onOpenTranscription, onOpenVoice: onOpenVoice)
                .frame(width: 380)
        }
        .accessibilityIdentifier("local-models.indicator")
        .accessibilityLabel(models.accessibilitySummary)
        .help(L("On-device speech and voice models: readiness and memory"))
    }
}

/// The detail card: one row per model, then the system memory bar.
struct LocalModelStatusPopover: View {
    @ObservedObject var models: LocalModelStatusStore
    var onOpenTranscription: (() -> Void)?
    var onOpenVoice: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("On-device models")).font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                LocalModelStatusRow(status: models.speechStatus, systemMemory: models.systemMemory,
                                    onOpenSettings: onOpenTranscription) { action in
                    switch action {
                    case .download: models.downloadSpeech()
                    case .prepare: models.prepareSpeech()
                    case .retry: models.retrySpeech()
                    }
                }
                Divider()
                LocalModelStatusRow(status: models.voiceStatus, systemMemory: models.systemMemory,
                                    onOpenSettings: onOpenVoice) { action in
                    switch action {
                    case .download: models.downloadVoice()
                    case .prepare: models.prepareVoice()
                    case .retry: models.retryVoice()
                    }
                }
            }
            Divider()
            systemMemoryBar
            Text(L("Memory figures estimate this app's own footprint while a model is loaded; they are not the model's download size."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .accessibilityIdentifier("local-models.popover")
        .onAppear { models.startSystemMemorySampling() }
        .onDisappear { models.stopSystemMemorySampling() }
    }

    private var systemMemoryBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(L("This Mac"), systemImage: "memorychip").font(.caption.weight(.medium))
                Spacer()
                if let memory = models.systemMemory {
                    Text(L("%@ used of %@", formatted(memory.used), formatted(memory.total)))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Measuring…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let memory = models.systemMemory, memory.total > 0 {
                ProgressView(value: min(1, Double(memory.used) / Double(memory.total)))
                    .accessibilityIdentifier("local-models.memory")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private enum LocalModelStatusAction { case download, prepare, retry }

/// One model: readiness pill, residency, compute path, memory estimate and actions.
private struct LocalModelStatusRow: View {
    let status: LocalModelStatusSnapshot
    let systemMemory: LocalSystemMemorySnapshot?
    let onOpenSettings: (() -> Void)?
    let action: (LocalModelStatusAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.title).font(.body.weight(.semibold))
                Spacer()
                readinessPill
            }
            if let modelName = status.modelName {
                Text(modelName).font(.caption).foregroundStyle(.secondary)
            }
            residencyLine
            computePath
            if case .downloading(let progress) = status.readiness {
                ProgressView(value: progress).controlSize(.small)
            }
            if status.memoryContended {
                Label(L("Measuring memory… another model loaded at the same time, so this estimate is hidden."),
                      systemImage: "ellipsis.circle").font(.caption).foregroundStyle(.secondary)
            } else if let estimate = status.memory, let systemMemory, systemMemory.available > 0 {
                Label(L("≈ %@ of %@ available", formatted(estimate.bytes), formatted(systemMemory.available)),
                      systemImage: "memorychip")
                    .font(.caption).foregroundStyle(.secondary)
            }
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(status.role == .speech ? "local-models.speech" : "local-models.voice")
    }

    private var readinessPill: some View {
        Label(readinessTitle, systemImage: readinessIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(readinessColor)
            .overlay(Capsule().stroke(readinessColor.opacity(0.6), lineWidth: 1))
            .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder private var residencyLine: some View {
        if status.residency != .notApplicable {
            Text(residencyTitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var computePath: some View {
        if !status.computePath.summary.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Label(status.computePath.summary, systemImage: "cpu").font(.caption.weight(.medium))
                if !status.computePath.detail.isEmpty {
                    Text(status.computePath.detail).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch status.readiness {
        case .notInstalled:
            Button(L("Download")) { action(.download) }.buttonStyle(.bordered).controlSize(.small)
        case .preparationNeeded:
            Button(L("Prepare")) { action(.prepare) }.buttonStyle(.bordered).controlSize(.small)
        case .failed:
            HStack(spacing: 8) {
                Button(L("Try again")) { action(.retry) }.buttonStyle(.bordered).controlSize(.small)
                if let onOpenSettings { Button(L("Open settings…")) { onOpenSettings() }.controlSize(.small) }
            }
        case .setupNeeded:
            if let onOpenSettings { Button(L("Open settings…")) { onOpenSettings() }.controlSize(.small) }
        case .preparing, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Preparing…")).font(.caption).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private var readinessTitle: String {
        switch status.readiness {
        case .off: return L("Off")
        case .unavailable: return L("Not supported")
        case .notInstalled: return L("Not installed")
        case .downloading: return L("Downloading")
        case .preparationNeeded: return L("Needs preparation")
        case .preparing: return L("Preparing")
        case .loading: return L("Loading")
        case .ready: return L("Ready")
        case .setupNeeded: return L("Setup needed")
        case .failed: return L("Failed")
        case .managed(let provider): return L("Managed by %@", provider)
        }
    }

    private var readinessIcon: String {
        switch status.readiness {
        case .off, .unavailable: return "minus.circle"
        case .notInstalled: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle"
        case .preparationNeeded, .preparing, .loading: return "ellipsis.circle"
        case .ready: return "checkmark.circle"
        case .setupNeeded: return "wrench.and.screwdriver"
        case .failed: return "exclamationmark.triangle"
        case .managed: return "applelogo"
        }
    }

    private var readinessColor: Color {
        switch status.readiness {
        case .ready: return .teal
        case .failed: return .red
        case .off, .unavailable, .managed: return .secondary
        default: return .orange
        }
    }

    private var residencyTitle: String {
        switch status.residency {
        case .loaded(let active): return active ? L("Loaded · in use") : L("Loaded · idle (ready to work)")
        case .loading: return L("Loading model…")
        case .unloading: return L("Unloading…")
        case .unloaded: return L("Not loaded")
        case .notApplicable: return ""
        }
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
