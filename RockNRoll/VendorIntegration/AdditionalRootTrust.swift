import Foundation
import Security
import UIKit

/// Adds the bundled public CA only to requests made with this session.
/// Normal iOS anchors remain valid, and the server's hostname must still match.
final class AdditionalRootTrust: NSObject, URLSessionDelegate {
    private let root: SecCertificate?

    override init() {
        if let data = NSDataAsset(name: "AdditionalRootCA")?.data {
            root = SecCertificateCreateWithData(nil, data as CFData)
        } else {
            root = nil
        }
        super.init()
        assert(root != nil, L("Bundled root certificate is missing"))
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let root else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #if DEBUG
        print("Additional root: evaluating \(challenge.protectionSpace.host)")
        #endif
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let anchorStatus = SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        let builtinStatus = SecTrustSetAnchorCertificatesOnly(trust, false)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        #if DEBUG
        print("Additional root: anchor=\(anchorStatus), builtins=\(builtinStatus), trusted=\(trusted)")
        #endif
        guard anchorStatus == errSecSuccess, builtinStatus == errSecSuccess, trusted else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
