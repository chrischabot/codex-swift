import Foundation
import Mem0Core

enum Mem0PrivacyGuard {
    static func containsDisallowedSecret(_ text: String) -> Bool {
        Mem0SecretScanner.containsSecret(text)
    }
}
