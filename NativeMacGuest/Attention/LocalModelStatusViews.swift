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
            stackedBar
            Text(legend).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Speech and voice live estimates as segments of total memory, everything
    /// else the Mac is doing in one segment, available memory as the track.
    /// Only live estimates are drawn; historical records stay in their rows.
    private var stackedBar: some View {
        let memory = models.systemMemory
        let total = Double(memory?.total ?? 0)
        let speechBytes = Double(models.speechStatus.memory?.bytes ?? 0)
        let voiceBytes = Double(models.voiceStatus.memory?.bytes ?? 0)
        let used = Double(memory?.used ?? 0)
        var fractions = total > 0 ? [speechBytes / total, voiceBytes / total, max(0, used - speechBytes - voiceBytes) / total] : [0, 0, 0]
        let sum = fractions.reduce(0, +)
        if sum > 1 { fractions = fractions.map { $0 / sum } }
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                HStack(spacing: 1.5) {
                    ForEach(Array(fractions.enumerated()), id: \.offset) { index, fraction in
                        if fraction > 0 {
                            Capsule().fill([Color.teal, Color.indigo, Color.blue.opacity(0.35)][index])
                                .frame(width: max(3, geometry.size.width * fraction), height: 6)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 6)
        .accessibilityIdentifier("local-models.memory")
        .accessibilityValue(legend)
    }

    private func isManaged(_ readiness: LocalModelReadiness) -> Bool {
        if case .managed = readiness { return true }
        return false
    }

    private var legend: String {
        var parts: [String] = []
        for status in [models.speechStatus, models.voiceStatus] {
            guard ![LocalModelReadiness.off, .unavailable].contains(status.readiness),
                  !isManaged(status.readiness) else { continue }
            if let estimate = status.memory {
                parts.append(L("%@ ≈%@", status.title, formatted(estimate.bytes)))
            } else {
                parts.append(L("%@ not measured", status.title))
            }
        }
        if let memory = models.systemMemory {
            let live = Double(models.speechStatus.memory?.bytes ?? 0) + Double(models.voiceStatus.memory?.bytes ?? 0)
            let other = max(0, Double(memory.used) - live)
            parts.append(L("other %@", formatted(UInt64(other))))
        }
        return parts.joined(separator: " · ")
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
            memoryBlock
            actions
            neuralEngineRecovery
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

    @ViewBuilder private var neuralEngineRecovery: some View {
        if let readiness = status.neuralEngineReadiness {
            switch readiness {
            case .failed, .preparationNeeded:
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Neural Engine preparation needs attention."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Try Neural Engine again")) { action(.retry) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            case .preparing, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Preparing Neural Engine…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .notInstalled:
                if let onOpenSettings {
                    Button(L("Set up Neural Engine…")) { onOpenSettings() }.controlSize(.small)
                }
            default:
                EmptyView()
            }
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

    /// Per-model memory figure, following the state matrix: live estimate while
    /// loaded, ghost last-known otherwise, honest "not measured" text otherwise.
    /// Managed and not-applicable models render no block at all.
    @ViewBuilder private var memoryBlock: some View {
        if status.neuralEngineReadiness != nil {
            Text(L("GPU model memory is not measured."))
                .font(.caption).foregroundStyle(.secondary)
        } else if status.residency == .notApplicable {
            EmptyView()
        } else if case .loading = status.residency {
            Label(status.memoryContended
                  ? L("Measuring memory… another model is loading")
                  : L("Measuring memory…"),
                  systemImage: "timer")
                .font(.caption).foregroundStyle(.secondary)
        } else if let estimate = status.memory {
            figure(bytes: estimate.bytes, ghost: false, caption: liveCaption(bytes: estimate.bytes))
        } else if let record = status.memoryLastKnown {
            if case .loaded = status.residency {
                figure(bytes: record.bytes, ghost: true,
                       caption: L("last measured %@ · not measured this session", date(record.measuredAt)))
            } else {
                figure(bytes: record.bytes, ghost: true,
                       caption: L("Last measured ≈ %@ · %@ · not loaded", formatted(record.bytes), date(record.measuredAt)))
            }
        } else if case .loaded = status.residency {
            Text(L("Not measured yet")).font(.caption).foregroundStyle(.secondary)
        } else {
            Text(L("No measurement yet — attributed on first load")).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One model's share of total memory as a thin bar above its provenance
    /// caption. The bar is omitted while the system total is still sampling.
    @ViewBuilder private func figure(bytes: UInt64, ghost: Bool, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let total = systemMemory?.total, total > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(roleColor.opacity(ghost ? 0.35 : 0.9))
                            .frame(width: max(3, geometry.size.width * min(1, Double(bytes) / Double(total))))
                    }
                }
                .frame(height: 5)
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func liveCaption(bytes: UInt64) -> String {
        if let total = systemMemory?.total, total > 0 {
            return L("≈ %@ of %@ · live estimate", formatted(bytes), formatted(total))
        }
        return L("≈ %@ · live estimate", formatted(bytes))
    }

    private var roleColor: Color {
        status.role == .speech ? .teal : .indigo
    }

    private func date(_ value: Date) -> String {
        value.formatted(.dateTime.day().month(.abbreviated))
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
