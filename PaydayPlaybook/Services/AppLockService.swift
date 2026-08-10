import Foundation
import LocalAuthentication
import SwiftUI

/// Optional app lock backed by device authentication (Face ID / Touch ID /
/// passcode). No custom PIN is ever stored.
@MainActor
final class AppLockService: ObservableObject {
    @Published var isLocked = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastError: String?

    var isEnabled = false

    static func biometryAvailable() -> Bool {
        var error: NSError?
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func lockIfEnabled() {
        guard isEnabled else { return }
        isLocked = true
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Payday Playbook to view your financial records."
            )
            if success {
                isLocked = false
            }
        } catch {
            lastError = "Authentication failed. Try again."
        }
    }
}
