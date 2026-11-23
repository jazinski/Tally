//
//  License.swift — offline license validation, global hotkey, frontmost tracking.
//
//  License keys are Ed25519-signed payloads verified against the embedded
//  public key — zero network calls, zero phone-home. Keys are issued with
//  tools/license-tool.swift (private key lives in .signing/, gitignored).
//

import AppKit
import Carbon.HIToolbox
import CryptoKit
import Foundation

extension Notification.Name {
    static let licenseChanged = Notification.Name("sashay.licenseChanged")
    static let settingsChanged = Notification.Name("sashay.settingsChanged")
}

struct License {
    let plan: String
    let email: String
    let expires: Date?

    var isActive: Bool { expires.map { $0 > Date() } ?? true }
}

final class LicenseManager {
    static let shared = LicenseManager()

    private static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "/eSGg/tkFBIpjfLKT6+zhk7HPtC8FqiZRurFYk3E0CQ=")!)

    private(set) var license: License?

    var isPro: Bool { license?.isActive ?? false }

    private var d: UserDefaults { UserDefaults.standard }

    init() { reload() }

    func reload() {
        guard let key = d.string(forKey: "license.key"), let lic = LicenseManager.parse(key) else {
            license = nil
            return
        }
        license = lic.isActive ? lic : nil
    }

    @discardableResult
    func activate(_ key: String) -> Bool {
        guard let lic = LicenseManager.parse(key), lic.isActive else { return false }
        license = lic
        d.set(key, forKey: "license.key")
        NotificationCenter.default.post(name: .licenseChanged, object: nil)
        return true
    }

    func deactivate() {
        d.removeObject(forKey: "license.key")
        license = nil
        NotificationCenter.default.post(name: .licenseChanged, object: nil)
    }

    private static func dataFromBase64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func parse(_ key: String) -> License? {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, parts[0] == "SASHAY1",
              let payload = dataFromBase64URL(String(parts[1])),
              let sig = dataFromBase64URL(String(parts[2])),
              publicKey.isValidSignature(sig, for: payload)
        else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let plan = obj["plan"] as? String,
              let email = obj["email"] as? String
        else { return nil }
        let exp = obj["exp"] as? Int ?? 0
        return License(plan: plan, email: email,
                       expires: exp > 0 ? Date(timeIntervalSince1970: Double(exp)) : nil)
    }
}

// MARK: - Global hotkey (Carbon — no extra permissions needed)

final class HotKeyCenter {
    var onToggle: () -> Void = {}
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func setEnabled(_ on: Bool) {
        if on, hotKeyRef == nil { register() }
        if !on, hotKeyRef != nil { unregister() }
    }

    private func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue()
            me.onToggle()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x53534859), id: 1)   // 'SSHY'
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}

// MARK: - Frontmost app tracking

final class FrontmostTracker {
    private(set) var lastOther: (bundle: String, name: String)?
    private var obs: Any?

    init() {
        obs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier
            else { return }
            self?.lastOther = (bid, app.localizedName ?? bid)
        }
    }

    var frontmostBundle: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
