import AuthenticationServices
import BelfryCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Security
import UIKit

// Keychain (the session), ASWebAuthenticationSession (sign-in), CoreImage (QR codes).

enum Keychain {
    static let service = "sh.belfry.app.session"
    /// The open account's slot (SPEC 19.24): its session is "session" ("") or "session@<slot>".
    static var slot = ""

    static func save(_ s: StoredSession, slot: String? = nil) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        let account = AccountList.sessionKey(slot ?? Keychain.slot)
        clear(slot: slot)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(slot: String? = nil) -> StoredSession? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: AccountList.sessionKey(slot ?? Keychain.slot),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    /// Forgets one account's session (the others stay).
    static func clear(slot: String? = nil) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: AccountList.sessionKey(slot ?? Keychain.slot)]
        SecItemDelete(q as CFDictionary)
    }
}

/// Small secrets by name in the Keychain (the native sign-in's pending request and session key).
final class KeychainVault: Vault {
    func get(_ key: String) -> String? { Keychain.string(key) }
    func set(_ key: String, _ value: String) { Keychain.setString(value, key) }
    func remove(_ key: String) { Keychain.removeString(key) }
}

@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Cancelled: Error { case cancelled }
    private var session: ASWebAuthenticationSession?

    func start(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback {
                    c.resume(returning: callback)
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    c.resume(throwing: Cancelled.cancelled)
                } else {
                    c.resume(throwing: error ?? Cancelled.cancelled)
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { c.resume(throwing: Cancelled.cancelled) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

enum QR {
    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
