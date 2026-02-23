import Foundation
import Darwin

enum SecureEventInput {
    private typealias IsSecureEventInputEnabledFn = @convention(c) () -> DarwinBoolean

    static func isEnabled() -> Bool {
        // Use a dynamic symbol lookup so we do not rely on static linkage details.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IsSecureEventInputEnabled") else {
            return false
        }
        let fn = unsafeBitCast(symbol, to: IsSecureEventInputEnabledFn.self)
        return fn().boolValue
    }
}
