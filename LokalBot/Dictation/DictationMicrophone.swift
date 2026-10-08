import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics

/// The microphone dictation records from. Empty means the macOS default
/// input, which follows AirPods when they connect; choosing the MacBook
/// microphone keeps a Bluetooth headset in its high-quality audio mode.
enum DictationMicrophone {
    struct Option: Equatable, Identifiable {
        let id: String
        let name: String
    }

    static func available() -> [Option] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { Option(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The preferred device when it is connected, otherwise the default input.
    static func device(preferredID: String) -> AVCaptureDevice? {
        if !preferredID.isEmpty {
            if let preferred = AVCaptureDevice(uniqueID: preferredID), preferred.isConnected {
                return preferred
            }
            lokalbotLog("dictation preferred microphone is not connected; using the default input")
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Picker rows: the default, every connected microphone, and a chosen one
    /// that is currently disconnected (so the choice stays visible).
    static func options(preferredID: String, available: [Option], defaultName: String) -> [Option] {
        var rows = [Option(id: "", name: defaultName)] + available
        if !preferredID.isEmpty, !available.contains(where: { $0.id == preferredID }) {
            rows.append(Option(id: preferredID, name: "Not connected"))
        }
        return rows
    }
}

/// While another app has Secure Input on (Terminal's Secure Keyboard Entry,
/// a password field, some password managers), macOS hides key presses from
/// event taps, so the dictation shortcut cannot be detected.
enum DictationSecureInput {
    /// Nil when Secure Input is off; otherwise the app holding it, if known.
    static func holder() -> String?? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return .some(name)
    }

    static func message(appName: String?, localized: (String) -> String = { $0 }) -> String {
        if let appName {
            return String(format: localized(
                "Secure Input is on in %@, so macOS hides the dictation shortcut. Turn it off there (for example Terminal → Secure Keyboard Entry) or switch apps."), appName)
        }
        return localized(
            "Secure Input is on in another app, so macOS hides the dictation shortcut. Turn it off there (for example Terminal → Secure Keyboard Entry) or switch apps.")
    }
}
