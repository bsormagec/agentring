import Foundation
import UIKit

/// Build and device facts.
enum AppInfo {
    static var bundleId: String { Bundle.main.bundleIdentifier ?? "dev.agentring.app" }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    /// APNs environment of this build's device tokens: Xcode debug builds talk to the
    /// sandbox, TestFlight / App Store builds to production (entitlement
    /// `aps-environment`, set from Config/Debug.xcconfig / Release.xcconfig).
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// What the relay lists in `agentring devices`. iOS only gives the generic name
    /// ("iPhone") without a special entitlement, so the model identifier is added.
    @MainActor
    static func deviceName() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let base = UIDevice.current.name
        let name = machine.isEmpty || machine.hasPrefix("x86") || machine.hasPrefix("arm64") ? base : "\(base) (\(machine))"
        return String(name.prefix(64))
    }
}

/// Lowercase hex of an APNs / PushKit token.
extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
