#if NATIVE_DIRECT_UPDATES
import Foundation

struct SupportCryptoWallet: Identifiable, Equatable {
    let id: String
    let asset: String
    let network: String
    let address: String
    let qrPayload: String
    let isERC20Token: Bool

    var displayName: String { "\(asset) · \(network)" }

    static let all: [SupportCryptoWallet] = [
        .init(
            id: "btc",
            asset: "BTC",
            network: "Bitcoin mainnet",
            address: "bc1q6e0ut7yst2tgxpfgy262h4mm238eqph2nm79ml",
            qrPayload: "bc1q6e0ut7yst2tgxpfgy262h4mm238eqph2nm79ml",
            isERC20Token: false
        ),
        .init(
            id: "eth",
            asset: "ETH",
            network: "Ethereum mainnet",
            address: "0xd094B9B06E328fD8Ea120A637078D7AD69A7172A",
            qrPayload: "ethereum:0xd094B9B06E328fD8Ea120A637078D7AD69A7172A@1",
            isERC20Token: false
        ),
        .init(
            id: "bnb",
            asset: "BNB",
            network: "BNB Smart Chain mainnet",
            address: "0xd094B9B06E328fD8Ea120A637078D7AD69A7172A",
            qrPayload: "ethereum:0xd094B9B06E328fD8Ea120A637078D7AD69A7172A@56",
            isERC20Token: false
        ),
        .init(
            id: "usdt",
            asset: "USDT",
            network: "Ethereum mainnet · ERC-20",
            address: "0xd094B9B06E328fD8Ea120A637078D7AD69A7172A",
            qrPayload: "ethereum:0xdAC17F958D2ee523a2206206994597C13D831ec7@1/transfer?address=0xd094B9B06E328fD8Ea120A637078D7AD69A7172A",
            isERC20Token: true
        ),
        .init(
            id: "usdc",
            asset: "USDC",
            network: "Ethereum mainnet · ERC-20",
            address: "0xd094B9B06E328fD8Ea120A637078D7AD69A7172A",
            qrPayload: "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48@1/transfer?address=0xd094B9B06E328fD8Ea120A637078D7AD69A7172A",
            isERC20Token: true
        ),
        .init(
            id: "sol",
            asset: "SOL",
            network: "Solana mainnet",
            address: "AwFswTyQrqw5ZbdgLbupHjLnDQCjvSurfApa5tRxHkVL",
            qrPayload: "AwFswTyQrqw5ZbdgLbupHjLnDQCjvSurfApa5tRxHkVL",
            isERC20Token: false
        ),
        .init(
            id: "trx",
            asset: "TRX",
            network: "Tron mainnet",
            address: "TLdLdzQazc9fBuc1kpv1wbCJMkWF5LPcbp",
            qrPayload: "TLdLdzQazc9fBuc1kpv1wbCJMkWF5LPcbp",
            isERC20Token: false
        ),
        .init(
            id: "kas",
            asset: "KAS",
            network: "Kaspa mainnet",
            address: "kaspa:prt3nsy3qx4qm5pvqdrg80nywqr045y94r7vmy2fj0nxtxdr74udcf86l5p3w",
            qrPayload: "kaspa:prt3nsy3qx4qm5pvqdrg80nywqr045y94r7vmy2fj0nxtxdr74udcf86l5p3w",
            isERC20Token: false
        ),
    ]
}
#endif
