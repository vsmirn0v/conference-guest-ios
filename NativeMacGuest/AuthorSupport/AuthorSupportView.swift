#if NATIVE_DIRECT_UPDATES
import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct AuthorSupportHeading: View {
    let title: String
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var spoken: Bool
    var body: some View {
        Text(title).accessibilityAddTraits(.isHeader).focusable().focused($focused)
            .accessibilityFocused($spoken)
            .onAppear { focused = true; spoken = true }
    }
}

@MainActor struct AuthorSupportView: View {
    private enum Method: String { case bank, boosty, hipolink }
    @ObservedObject private var service = AuthorSupportService.shared
    @State private var monthly = true
    @State private var amount = 299
    @State private var method: Method = SupportCopy.russian ? .bank : .hipolink
    @State private var tip: Decimal? = 9
    @State private var claimOpen = false
    @State private var working = false
    @State private var feedback = ""
    @State private var showPhone = false

    private func t(_ key: String) -> String { SupportCopy.text(key) }
    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.wide).day().locale(SupportCopy.locale))
    }
    private var tier: AuthorSupportTier? {
        service.monthlyTiers.first { $0.amountRUB == amount } ?? service.monthlyTiers.first { $0.amountRUB == 299 } ?? service.monthlyTiers.first
    }
    private var offeredMethods: [Method] {
        var result: [Method] = []
        if service.bankURL != nil { result.append(.bank) }
        if service.boostyOneTimeURL != nil { result.append(.boosty) }
        if service.hipolinkTipsURL != nil || service.boostyOneTimeURL != nil { result.append(.hipolink) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(t("Rock’n’Roll is free and open source. I test calls, fix audio issues, and keep the app working across macOS releases. If it helps you, you can support my work."))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { projectLinks }
                    VStack(alignment: .leading, spacing: 7) { projectLinks }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Picker(t("Support frequency"), selection: $monthly) {
                        Text(t("Monthly")).tag(true)
                        Text(t("One time")).tag(false)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("author-support.frequency")
                    if monthly { monthlyContent } else { oneTimeContent }
                    if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.secondary) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                Text(t("Giving is voluntary. All features stay free. Support does not buy priority service or specific development work."))
                    .font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: 680, alignment: .leading).padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: monthly) { _ in clearHandoff() }
        .onChange(of: amount) { _ in clearHandoff() }
        .onChange(of: method) { _ in clearHandoff() }
        .onChange(of: service.monthlyTiers.map(\.checkoutURL) + [service.bankURL, service.boostyOneTimeURL, service.hipolinkTipsURL].compactMap { $0 }) { _ in clearHandoff() }
        .task { await service.refresh() }
    }

    @ViewBuilder private var projectLinks: some View {
        Link(destination: URL(string: "https://github.com/vsmirn0v/rocknroll")!) {
            Label(t("Source on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Link(destination: URL(string: "https://testflight.apple.com/join/Hd13C9U3")!) {
            Label(t("iOS public beta"), systemImage: "iphone")
        }
        Link(destination: URL(string: "https://rock.glowsoft.ru/")!) {
            Label("rock.glowsoft.ru", systemImage: "globe")
        }
    }
    private func clearHandoff() { showPhone = false; feedback = "" }

    @ViewBuilder private var monthlyContent: some View {
        switch service.claim {
        case .active(let through) where service.hasActiveSubscription(at: Date()):
            Label(t("This Mac is linked"), systemImage: "checkmark.circle").font(.headline)
            Text(SupportCopy.text("Support confirmed through %@", day(through)))
            Text(t("Thank you! Home reminders are paused for this period. You can manage your subscription on Boosty."))
                .font(.callout).foregroundStyle(.secondary)
            Link(t("Open the author’s Boosty page"), destination: URL(string: "https://boosty.to/rwrt")!)
        case .pending:
            Label(t("Awaiting verification"), systemImage: "clock").font(.headline)
            Text(t("The author checks the subscribed account and its paid-through date. You can leave this page and return later."))
            Button(t("Check status")) { run { try await service.refreshClaim() } }.disabled(working)
        case .code(let code, let expiry) where claimOpen && expiry > Date():
            claimCode(code, expires: expiry)
        default:
            if let tier {
                Text(t("Monthly amount on Boosty")).font(.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { tierPicker; primaryLink(t("Continue on Boosty"), tier.checkoutURL) }
                    VStack(alignment: .leading) { tierPicker; primaryLink(t("Continue on Boosty"), tier.checkoutURL) }
                }
                Text(t("Renews monthly. You can cancel future renewals on Boosty.")).font(.callout)
                if donorQuote(tier) != nil, let asOf = service.quoteDate {
                    Text(SupportCopy.text("Price shown by Boosty on %@. Confirm the currency and final charge at checkout.", day(asOf)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                phoneActions(tier.checkoutURL)
            }
            Divider()
            Text(t("Already subscribed on Boosty?")).font(.callout)
            Text(t("Linking sends a random device identifier and a claim reference to rock.glowsoft.ru so this Mac can check your support period."))
                .font(.caption).foregroundStyle(.secondary)
            Button(t("Link this Mac")) {
                run {
                    if case .code(_, let expiry) = service.claim, expiry > Date() { claimOpen = true }
                    else { try await service.startClaim(); claimOpen = true }
                }
            }.disabled(working).accessibilityIdentifier("author-support.link")
        }
    }

    private var tierPicker: some View {
        Picker(t("Monthly amount on Boosty"), selection: Binding(get: { tier?.amountRUB ?? -1 }, set: { amount = $0 })) {
            ForEach(service.monthlyTiers, id: \.amountRUB) { item in Text(tierPrice(item)).tag(item.amountRUB) }
        }.labelsHidden().fixedSize().accessibilityIdentifier("author-support.amount")
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
            if service.bankURL != nil { Text(t("T-Bank · From Russia")).tag(Method.bank) }
            if service.boostyOneTimeURL != nil { Text(t("Boosty · Russia and international")).tag(Method.boosty) }
            if service.hipolinkTipsURL != nil || service.boostyOneTimeURL != nil { Text(t("Hipolink · International tips")).tag(Method.hipolink) }
        }.pickerStyle(.radioGroup).accessibilityIdentifier("author-support.one-time-method")
        Divider()
        switch shownMethod {
        case .bank:
            if let url = service.bankURL {
                Text(t("In T-Bank, check the organizer Виталий С. and the collection «Сбор на другое»."))
                primaryLink(t("Open T-Bank"), url); phoneActions(url)
            }
        case .boosty:
            if let url = service.boostyOneTimeURL {
                Text(t("Choose the amount on the author’s Boosty page. Available methods depend on your country and bank."))
                primaryLink(t("Give once on Boosty"), url); phoneActions(url)
            }
        case .hipolink:
            if let base = service.hipolinkTipsURL {
                TextField(t("Suggested tip (USD)"), value: $tip, format: .number.locale(SupportCopy.locale))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 170)
                if let url = hipolinkURL(base) { primaryLink(t("Continue on Hipolink"), url); phoneActions(url) }
                else { Text(t("Enter an amount from USD 0.10 to 800.00 with up to two decimal places.")).font(.callout) }
            } else if let url = service.boostyOneTimeURL {
                Text(t("Hipolink tips are awaiting account verification. You can give once on Boosty and choose your amount there."))
                primaryLink(t("Give once on Boosty"), url)
            }
        }
        }
    }
    private func hipolinkURL(_ base: URL) -> URL? {
        guard let tip, tip >= Decimal(1) / 10, tip <= 800,
              var url = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var original = tip, rounded = Decimal()
        NSDecimalRound(&rounded, &original, 2, .plain)
        guard rounded == tip else { return nil }
        url.queryItems = [.init(name: "currency", value: "USD"), .init(name: "amount", value: NSDecimalNumber(decimal: tip).stringValue)]
        return url.url
    }
    private func primaryLink(_ label: String, _ url: URL) -> some View {
        Link(label, destination: url).buttonStyle(.borderedProminent)
    }
    private func phoneActions(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Button { showPhone.toggle() } label: { Label(t("Open on your phone"), systemImage: "qrcode") }
                Button(t("Copy link")) { copy(url.absoluteString) }
            }.buttonStyle(.link)
            if showPhone {
                if let image = Self.qrImage(url) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 144, height: 144)
                        .padding(10).background(Color.white).accessibilityLabel(t("QR code for the link below"))
                }
                Text(verbatim: url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
    private static func qrImage(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
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
