#if NATIVE_DIRECT_UPDATES
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor struct AuthorSupportView: View {
    private enum Method { case boosty, bank, crypto }
    var focusOnEntry: Binding<Bool> = .constant(false)
    @ObservedObject private var service = AuthorSupportService.shared
    @State private var monthly = true
    @State private var amount = 299
    @State private var method: Method = .boosty
    @State private var cryptoAssetID = SupportCryptoWallet.all[0].id
    @State private var linkDetails = false
    @State private var claimOpen = false
    @State private var working = false
    @State private var feedback = ""
    @State private var showPhone = false
    @FocusState private var headingFocused: Bool
    @AccessibilityFocusState(for: .voiceOver) private var headingSpoken: Bool

    private func t(_ key: String) -> String { SupportCopy.text(key) }
    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day().locale(SupportCopy.locale))
    }
    private var tier: AuthorSupportTier? {
        service.monthlyTiers.first { $0.amountRUB == amount } ?? service.monthlyTiers.first { $0.amountRUB == 299 } ?? service.monthlyTiers.first
    }
    private var selectedCryptoWallet: SupportCryptoWallet {
        SupportCryptoWallet.all.first { $0.id == cryptoAssetID } ?? SupportCryptoWallet.all[0]
    }
    private var offeredMethods: [Method] {
        var result: [Method] = []
        if service.boostyOneTimeURL != nil { result.append(.boosty) }
        if service.bankURL != nil { result.append(.bank) }
        if SupportCopy.isOutsideRussia() { result.append(.crypto) }
        return result
    }
    private var shownMethod: Method? { offeredMethods.contains(method) ? method : offeredMethods.first }
    private func donorQuote(_ tier: AuthorSupportTier) -> (amount: Decimal, currency: String)? {
        guard !SupportCopy.russian else { return nil }
        if Locale.current.currency?.identifier == "EUR", let eur = tier.eur { return (eur, "EUR") }
        return tier.usd.map { ($0, "USD") }
    }
    private func tierPrice(_ tier: AuthorSupportTier) -> String {
        let rubles = SupportCopy.money(Decimal(tier.amountRUB), code: "RUB")
        if let quote = donorQuote(tier) {
            return SupportCopy.text("%1$@ per month · %2$@", SupportCopy.money(quote.amount, code: quote.currency), rubles)
        }
        return SupportCopy.text("%@ per month", rubles)
    }

    var body: some View {
        let claim = visibleClaim
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Text(t("Rock’n’Roll is free and open source. Your support helps me test calls, fix audio issues, and ship macOS updates."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    NativeSegmentedControl(
                        label: t("Support frequency"),
                        selection: $monthly,
                        options: [
                            .init(value: true, title: t("Monthly")),
                            .init(value: false, title: t("One time")),
                        ],
                        accessibilityID: "author-support.frequency"
                    )
                    if monthly { monthlyContent(claim) } else { oneTimeContent }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                if monthly, case .none = claim { linkDisclosure }
                if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.secondary) }
                footer
            }.frame(maxWidth: 600, alignment: .leading).padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(.gray)
        .onChange(of: monthly) { _ in clearHandoff() }
        .onChange(of: amount) { _ in clearHandoff() }
        .onChange(of: method) { _ in clearHandoff() }
        .onChange(of: cryptoAssetID) { _ in clearHandoff() }
        .onChange(of: service.monthlyTiers.map(\.checkoutURL) + [service.bankURL, service.boostyOneTimeURL].compactMap { $0 }) { _ in clearHandoff() }
        .task { await service.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().interpolation(.high).frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(t("Support the author")).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .focusable().focused($headingFocused).accessibilityFocused($headingSpoken)
                    .onAppear {
                        if focusOnEntry.wrappedValue {
                            headingFocused = true
                            focusOnEntry.wrappedValue = false
                        }
                        if NSWorkspace.shared.isVoiceOverEnabled { headingSpoken = true }
                    }
                Text(t("Voluntary support")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { projectLinks }
                VStack(alignment: .leading, spacing: 7) { projectLinks }
            }.font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { cooperationContact }
                VStack(alignment: .leading, spacing: 2) { cooperationContact }
            }.font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(t("Voluntary support does not unlock features, priority service, or work on request. All features are free."))
                Text(t("Rock’n’Roll is the author’s personal project. It is independent of the author’s employer and has no employer endorsement."))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cooperationContact: some View {
        Text(t("Cooperation inquiries with the app developer:"))
        Link(destination: URL(string: "mailto:info@glowsoft.ru")!) {
            Text(verbatim: "info@glowsoft.ru")
                .foregroundStyle(.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder private var projectLinks: some View {
        Link(destination: URL(string: "https://github.com/vsmirn0v/rocknroll")!) {
            Text(t("Source on GitHub")).foregroundStyle(.secondary)
        }
        Link(destination: URL(string: "https://testflight.apple.com/join/Hd13C9U3")!) {
            Text(t("iOS public beta")).foregroundStyle(.secondary)
        }
        Link(destination: URL(string: "https://rock.glowsoft.ru/")!) {
            Text(verbatim: "rock.glowsoft.ru").foregroundStyle(.secondary)
        }
    }
    private func clearHandoff() { showPhone = false; feedback = "" }

    private var visibleClaim: AuthorSupportClaimState {
        switch service.claim {
        case .active where service.hasActiveSubscription(at: Date()), .pending:
            return service.claim
        case .code(_, let expiry) where claimOpen && expiry > Date():
            return service.claim
        default:
            return .none
        }
    }

    @ViewBuilder private func monthlyContent(_ claim: AuthorSupportClaimState) -> some View {
        switch claim {
        case .active(let through):
            Label(t("This Mac is linked"), systemImage: "checkmark.circle").font(.headline)
            Text(SupportCopy.text("Support confirmed through %@", day(through)))
            Text(t("Thank you! Home reminders are paused for this period. You can manage your subscription on Boosty."))
                .font(.callout).foregroundStyle(.secondary)
            Link(t("Open the author’s Boosty page"), destination: URL(string: "https://boosty.to/rwrt")!)
        case .pending:
            Label(t("Awaiting verification"), systemImage: "clock").font(.headline)
            Text(t("The author checks the subscribed account and its paid-through date. You can leave this page and return later."))
            Button(t("Check status")) { run { try await service.refreshClaim() } }.disabled(working)
        case .code(let code, let expiry):
            claimCode(code, expires: expiry)
        case .none:
            if let tier {
                Text(t("Monthly amount on Boosty")).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { tierPicker.fixedSize(); primaryLink(t("Continue on Boosty"), tier.checkoutURL).fixedSize() }
                    VStack(alignment: .leading) { tierPicker; primaryLink(t("Continue on Boosty"), tier.checkoutURL) }
                }
                Text(t("Renews monthly. You can cancel future renewals on Boosty.")).font(.callout).foregroundStyle(.secondary)
                if donorQuote(tier) != nil, let asOf = service.quoteDate {
                    Text(SupportCopy.text("Price shown by Boosty on %@. Confirm the currency and final charge at checkout.", day(asOf)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                phoneActions(tier.checkoutURL)
            }
        }
    }

    private var linkDisclosure: some View {
        DisclosureGroup(isExpanded: $linkDetails) {
            Text(t("Linking sends a random device identifier and a claim reference to rock.glowsoft.ru so this Mac can check your support period."))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            Button(t("Request a code")) {
                run {
                    try await service.startClaim()
                    clearHandoff()
                    claimOpen = true
                }
            }.disabled(working).padding(.top, 4).accessibilityIdentifier("author-support.link.request")
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { linkLabel }
                VStack(alignment: .leading, spacing: 3) { linkLabel }
            }.font(.callout)
        }
        .accessibilityIdentifier("author-support.link")
    }

    @ViewBuilder private var linkLabel: some View {
        Text(t("Already subscribed on Boosty?")).foregroundStyle(.secondary)
        Text(t("Link this Mac")).fontWeight(.medium)
    }

    private var tierPicker: some View {
        Picker(t("Monthly amount on Boosty"), selection: Binding(get: { tier?.amountRUB ?? -1 }, set: { amount = $0 })) {
            ForEach(service.monthlyTiers, id: \.amountRUB) { item in Text(tierPrice(item)).tag(item.amountRUB) }
        }.labelsHidden().accessibilityIdentifier("author-support.amount")
    }

    private func claimCode(_ code: String, expires: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t("Link this Mac to Boosty"), systemImage: "laptopcomputer").font(.headline)
            Text(t("On your phone, sign in to the Boosty account you used to subscribe. Send this code to the author in a private message on boosty.to/rwrt."))
            HStack {
                Text(verbatim: code).font(.title3.monospaced().bold()).textSelection(.enabled).environment(\.layoutDirection, .leftToRight)
                Button(t("Copy code")) { copy(code) }
            }
            Text(SupportCopy.text("Code expires at %@", expires.formatted(.dateTime.hour().minute().locale(SupportCopy.locale))))
                .font(.caption).foregroundStyle(.secondary)
            phoneActions(URL(string: "https://boosty.to/rwrt")!)
            Button(t("I’ve sent the code")) { run { try await service.markClaimSent() } }
                .buttonStyle(.borderedProminent).disabled(working)
            Button(t("Back to monthly support")) { claimOpen = false; clearHandoff() }.buttonStyle(.link)
        }
    }

    @ViewBuilder private var oneTimeContent: some View {
        if let shownMethod {
            Picker(t("One-time support method"), selection: Binding(get: { shownMethod }, set: { method = $0 })) {
                if service.boostyOneTimeURL != nil { Text(t("Boosty · Russia and international")).tag(Method.boosty) }
                if service.bankURL != nil { Text(t("Bank transfer · From Russia")).tag(Method.bank) }
                if SupportCopy.isOutsideRussia() { Text(t("Cryptocurrency · International")).tag(Method.crypto) }
            }.accessibilityIdentifier("author-support.one-time-method")
            switch shownMethod {
            case .boosty:
                if let url = service.boostyOneTimeURL {
                    primaryLink(t("Give once on Boosty"), url)
                    Text(t("Choose the amount on the author’s Boosty page. Available methods depend on your country and bank."))
                        .font(.callout).foregroundStyle(.secondary)
                    phoneActions(url)
                }
            case .bank:
                if let url = service.bankURL {
                    primaryLink(t("Open bank transfer"), url)
                    Text(t("Before confirming the transfer, check that the recipient is Виталий С."))
                        .font(.callout).foregroundStyle(.secondary)
                    phoneActions(url)
                }
            case .crypto:
                cryptoContent
            }
        }
    }

    private var cryptoContent: some View {
        let wallet = selectedCryptoWallet
        return VStack(alignment: .leading, spacing: 12) {
            Picker(t("Asset and network"), selection: $cryptoAssetID) {
                ForEach(SupportCryptoWallet.all) { item in
                    Text(verbatim: item.displayName).tag(item.id)
                }
            }.accessibilityIdentifier("author-support.crypto-asset")
            Text(t("Select this asset and network in your wallet, then verify the full receiving address before sending. You choose the amount."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if wallet.isERC20Token {
                Text(t("For manual entry, select this token on Ethereum mainnet and paste the receiving address."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(t("Copy address")) { copy(wallet.address) }
                .accessibilityIdentifier("author-support.crypto-copy")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { cryptoWalletDetails(wallet) }
                VStack(alignment: .leading, spacing: 10) { cryptoWalletDetails(wallet) }
            }
        }
    }

    @ViewBuilder private func cryptoWalletDetails(_ wallet: SupportCryptoWallet) -> some View {
        if let image = Self.qrImage(wallet.qrPayload) {
            Image(nsImage: image).interpolation(.none).resizable().frame(width: 144, height: 144)
                .padding(10).background(Color.white).accessibilityLabel(t("QR code for the receiving address"))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Receiving address")).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: wallet.address).font(.callout.monospaced()).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
    private func primaryLink(_ label: String, _ url: URL) -> some View {
        Link(label, destination: url).buttonStyle(CheckoutButtonStyle())
    }

    private struct CheckoutButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(red: 0.17, green: 0.08, blue: 0.02))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 1, green: 0.65, blue: 0.34).opacity(configuration.isPressed ? 0.83 : 1))
                }
        }
    }
    private func phoneActions(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { phoneButtons(url) }
                VStack(alignment: .leading, spacing: 6) { phoneButtons(url) }
            }.font(.caption).buttonStyle(.plain)
            if showPhone {
                if let image = Self.qrImage(url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 144, height: 144)
                        .padding(10).background(Color.white).accessibilityLabel(t("QR code for the link below"))
                }
                Text(verbatim: url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
    @ViewBuilder private func phoneButtons(_ url: URL) -> some View {
        Button { showPhone.toggle() } label: {
            Label(t("Open on your phone"), systemImage: "qrcode").foregroundStyle(.secondary)
        }.accessibilityAddTraits(showPhone ? .isSelected : [])
        Button { copy(url.absoluteString) } label: {
            Label(t("Copy link"), systemImage: "doc.on.doc").foregroundStyle(.secondary)
        }
    }
    private static func qrImage(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(value, forType: .string) { feedback = t("Copied to clipboard.") }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; feedback = ""
        Task { @MainActor in
            defer { working = false }
            do { try await operation() }
            catch { feedback = t("Couldn’t check with the support service. Try again when connected.") }
        }
    }
}
#endif
