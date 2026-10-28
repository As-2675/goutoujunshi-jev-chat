import Foundation
#if os(iOS)
import Security
import UIKit
#endif

struct KeyboardHandoff: Codable {
    var transcript: String
    var advice: Advice
    var relationship: Relationship
    var config: AppConfig
    var createdAt: Date

    func valid(at date: Date, relationship current: Relationship, config currentConfig: AppConfig) -> Bool {
        let age = date.timeIntervalSince(createdAt)
        return (0...300).contains(age) && current == relationship && currentConfig == config
    }
}

/// A single resumable round, never an archive or an authorization to analyze/insert.
/// Images, typing composition, credentials and confirmation state are excluded.
struct KeyboardSession: Codable {
    var transcript: String
    var advice: Advice?
    var relationship: Relationship
    var config: AppConfig
    var createdAt: Date

    func valid(at date: Date, relationship current: Relationship, config currentConfig: AppConfig) -> Bool {
        (0...300).contains(date.timeIntervalSince(createdAt)) &&
        current == relationship && currentConfig == config &&
        !transcript.trimmed.isEmpty && transcript.count <= 12_000
    }
}

final class GoutouStore {
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "GoutouAppGroup") as? String ?? "group.ai.goutoujunshi.chatios" }
    private let defaults: UserDefaults
    private let container: URL

    init() throws {
        #if os(iOS)
        // 免费签名 / Sideload 时 App Group entitlement 可能拿不到；工厂里若直接 throw，
        // 整个 App 会在启动时就报「共享配置未连接」。所以先探测，不通就降级到本机私有目录：
        // App 保持可用，与键盘的共享退化为不可用（键盘侧会提示未连接）。
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group),
           let defaults = UserDefaults(suiteName: Self.group),
           Self.sharedContainerUsable(container, defaults: defaults) {
            self.container = container
            self.defaults = defaults
        } else {
            let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            self.container = local
            self.defaults = .standard
        }
        #else
        container = FileManager.default.temporaryDirectory.appendingPathComponent("goutou-ios-core-tests")
        defaults = UserDefaults(suiteName: "ai.goutoujunshi.core-tests")!
        #endif
        purgeExpiredHandoff()
        captureMailbox.purge(relationship: relationship(), config: config())
        _ = keyboardSession()
    }

    /// App Group 是否真的可写可读：entitlement 缺失时 `containerURL` 可能返回路径但写不进去，
    /// `UserDefaults(suiteName:)` 也可能返回一个写进去读不回来的空壳，所以两边都做一次写读探测。
    private static func sharedContainerUsable(_ container: URL, defaults: UserDefaults) -> Bool {
        let stamp = UUID().uuidString
        defaults.set(stamp, forKey: "goutou.canary")
        guard defaults.string(forKey: "goutou.canary") == stamp else { return false }
        let probe = container.appendingPathComponent(".goutou.canary")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            let readable = (try? Data(contentsOf: probe))?.count == 2
            try? FileManager.default.removeItem(at: probe)
            return readable
        } catch {
            return false
        }
    }

    init(defaults: UserDefaults, container: URL) {
        self.defaults = defaults; self.container = container
        purgeExpiredHandoff()
        captureMailbox.purge(relationship: relationship(), config: config())
        _ = keyboardSession()
    }

    func config() -> AppConfig { decode("config", fallback: AppConfig()) }
    func saveConfig(_ value: AppConfig) throws {
        try value.validate()
        try save(value, key: "config")
        clearHandoff()
        captureMailbox.clear()
        clearKeyboardSession()
    }
    func relationship() -> Relationship { decode("relationship", fallback: Relationship(id: "current")) }
    func saveRelationship(_ value: Relationship, archive: Bool) throws {
        try value.validate()
        if archive {
            var profiles = archived()
            profiles.removeAll { $0.id == value.id }
            profiles.append(value)
            guard profiles.count <= 100 else { throw GoutouError.invalid("对象档案最多 100 个，请先清理") }
            try save(profiles, key: "profiles")
        }
        try save(value, key: "relationship")
        clearHandoff()
        captureMailbox.clear()
        clearKeyboardSession()
    }
    func archived() -> [Relationship] { decode("profiles", fallback: []) }
    func deleteProfile(_ id: String) throws {
        try save(archived().filter { $0.id != id }, key: "profiles")
        if relationship().id == id { try saveRelationship(Relationship(id: "current"), archive: false) }
    }
    func clearProfiles() {
        defaults.removeObject(forKey: "profiles")
        defaults.removeObject(forKey: "relationship")
        clearHandoff()
        captureMailbox.clear()
        clearKeyboardSession()
    }
    func setKeyboardStatus(fullAccess: Bool) {
        defaults.set(fullAccess, forKey: "keyboardFullAccess")
        defaults.set(Date().timeIntervalSince1970, forKey: "keyboardLastSeen")
    }
    var keyboardStatus: String {
        guard let seen = defaults.object(forKey: "keyboardLastSeen") as? Double, Date().timeIntervalSince1970 - seen < 86_400 else {
            return "尚未检测到键盘；请到聊天输入框切换一次"
        }
        return defaults.bool(forKey: "keyboardFullAccess") ? "最近已连接 · 完全访问已开启" : "最近已连接 · 需要开启完全访问"
    }
    private func save<T: Encodable>(_ value: T, key: String) throws { defaults.set(try JSONEncoder().encode(value), forKey: key) }
    private func decode<T: Decodable>(_ key: String, fallback: T) -> T {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    /// This is an explicit one-time handoff, never an automatic chat archive.
    func handoff(_ value: KeyboardHandoff) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 512_000 else { throw GoutouError.invalid("本轮内容过大，无法交给键盘") }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.appendingPathComponent("handoff.json")
        #if os(iOS)
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            var excluded = path
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try excluded.setResourceValues(resource)
        } catch { clearHandoff(); throw error }
        #else
        try data.write(to: path, options: .atomic)
        #endif
    }
    func takeHandoff() -> KeyboardHandoff? {
        let path = container.appendingPathComponent("handoff.json")
        defer { clearHandoff() }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: path), let result = try? JSONDecoder().decode(KeyboardHandoff.self, from: data),
              result.valid(at: Date(), relationship: relationship(), config: config()) else { return nil }
        return result
    }
    /// iOS cannot guarantee background deletion at an exact deadline. Expired data
    /// is unusable immediately and is removed when either process next opens it.
    func purgeExpiredHandoff() {
        let path = container.appendingPathComponent("handoff.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: path),
              let value = try? JSONDecoder().decode(KeyboardHandoff.self, from: data),
              value.valid(at: Date(), relationship: relationship(), config: config()) else {
            clearHandoff(); return
        }
    }
    func clearHandoff() { try? FileManager.default.removeItem(at: container.appendingPathComponent("handoff.json")) }
    func saveKeyboardSession(_ value: KeyboardSession) throws {
        guard value.valid(at: Date(), relationship: relationship(), config: config()) else {
            throw GoutouError.invalid("本轮暂存已过期或对象已变化，请重新读取")
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 512_000 else { throw GoutouError.invalid("本轮内容过大，无法暂存") }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.appendingPathComponent("keyboard-session.json")
        #if os(iOS)
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            var file = path, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch { clearKeyboardSession(); throw error }
        #else
        try data.write(to: path, options: .atomic)
        #endif
    }
    /// Read without consuming so dismissing/recreating the keyboard can resume.
    func keyboardSession() -> KeyboardSession? {
        let path = container.appendingPathComponent("keyboard-session.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(KeyboardSession.self, from: data),
              value.valid(at: Date(), relationship: relationship(), config: config()) else {
            clearKeyboardSession(); return nil
        }
        return value
    }
    func clearKeyboardSession() {
        try? FileManager.default.removeItem(at: container.appendingPathComponent("keyboard-session.json"))
    }
    var captureMailbox: CaptureMailbox { CaptureMailbox(container: container) }
}

#if !GOUTOU_CAPTURE
enum CredentialVault {
    static let services = ["deepseek", "openrouter", "jev"]
    #if os(iOS)
    /// 免费签名 / Sideload 时，自定义 keychain access group 拿不到授权（SecItem 返回 -34018），
    /// 所以凭据优先写进 App Group 容器里的文件：App 与键盘都能读，且不需要额外 entitlement。
    /// keychain 保留为兜底——正常 Team 签名下它依然可用，之前存进去的 key 也能读回来。
    private static var groupContainer: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "GoutouAppGroup") as? String,
              !group.contains("$("), !group.isEmpty else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// 本机私有目录：免费签名下 App Group 拿不到时，凭据退到这里（App 与键盘各存各的，
    /// 键盘那份靠「从剪贴板导入配置」灌进来）。
    private static var localContainer: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var containers: [URL] {
        groupContainer.map { [$0, localContainer] } ?? [localContainer]
    }

    private static func readFileMap() -> [String: String] {
        for container in containers {
            if let data = try? Data(contentsOf: container.appendingPathComponent("credentials.json")),
               let map = try? JSONDecoder().decode([String: String].self, from: data) {
                return map
            }
        }
        return [:]
    }

    private static func writeFileMap(_ map: [String: String]) throws {
        let data = try JSONEncoder().encode(map)
        var lastError: Error?
        for container in containers {
            do {
                try data.write(to: container.appendingPathComponent("credentials.json"),
                                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GoutouError.invalid("共享容器不可用，无法保存密钥")
    }

    private static var declaredGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "GoutouKeychainGroup") as? String,
              !group.contains("$("), !group.isEmpty else { return nil }
        return group
    }

    private static func keychainQuery(_ name: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "ai.goutoujunshi.ios." + name,
                                    kSecAttrAccount as String: "default"]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private static func keychainRead(_ name: String) -> String? {
        for group in [declaredGroup, nil] {
            var query = keychainQuery(name, group: group)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func keychainWrite(_ name: String, _ value: String) -> Bool {
        for group in [declaredGroup, nil] {
            let query = keychainQuery(name, group: group)
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
            }
            if status == errSecSuccess { return true }
        }
        return false
    }

    static func read(_ name: String) throws -> String {
        guard services.contains(name) else { throw GoutouError.invalid("未知的凭据名：\(name)") }
        if let value = readFileMap()[name], !value.isEmpty { return value }
        return keychainRead(name) ?? ""
    }

    static func write(_ value: String, name: String) throws {
        let value = value.trimmed
        guard services.contains(name) else { throw GoutouError.invalid("未知的凭据名：\(name)") }
        guard !value.isEmpty, value.count <= 1024 else { throw GoutouError.invalid("请输入有效的 API Key") }
        var map = readFileMap()
        map[name] = value
        do {
            try writeFileMap(map)
            return
        } catch {
            if keychainWrite(name, value) { return }
            throw error
        }
    }

    static func delete(_ name: String) throws {
        guard services.contains(name) else { throw GoutouError.invalid("未知的凭据名：\(name)") }
        var map = readFileMap()
        if map.removeValue(forKey: name) != nil { try? writeFileMap(map) }
        for group in [declaredGroup, nil] {
            _ = SecItemDelete(keychainQuery(name, group: group) as CFDictionary)
        }
    }
    #else
    static func read(_ name: String) throws -> String { "" }
    static func write(_ value: String, name: String) throws { throw GoutouError.invalid("请在 iOS App 中配置密钥") }
    static func delete(_ name: String) throws {}
    #endif

    static func load() throws -> ProviderSecrets {
        try ProviderSecrets(deepseek: read("deepseek"), openrouter: read("openrouter"), jev: read("jev"))
    }
}
#endif

// MARK: - 剪贴板搬运（免费签名下 App Group 拿不到时的唯一通道）

/// 免费账号签名的包没有 App Group：App 与键盘各自落在自己的容器里，配置、密钥、
/// 截屏结果都没法共享。剪贴板是唯一还能用的通道，方向固定为 **App → 键盘**——
/// 键盘有完全访问，读剪贴板不弹授权；反过来让 App 读剪贴板会弹「允许粘贴」，会卡住自动化。
struct GoutouHandoffPayload: Codable {
    var config: AppConfig
    var relationship: Relationship
    var secrets: [String: String]
    /// 主 App 里保存过的对象档案。免费签名下键盘读不到 App 的存储，
    /// 不带过来的话「选择对象」菜单里只剩一个空对象，切不了。
    var profiles: [Relationship]? = nil
    var createdAt: Date
}

/// 剪贴板截图包：识别结果 + 主 App 当前的配置、对象与密钥。
/// 免费签名下键盘读不到这些，顺手捎一次，省掉手动导入那一步。
struct GoutouCaptureEnvelope: Codable {
    var result: KeyboardCaptureResult
    var config: AppConfig
    var relationship: Relationship
    var secrets: [String: String]
    var profiles: [Relationship]? = nil
    var createdAt: Date
}

enum GoutouClipboard {
    static let configMarker = "GOUTOUCFG1:"
    static let captureMarker = "GOUTOURES1:"

    static func encode<T: Encodable>(_ value: T, marker: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return marker + data.base64EncodedString()
    }

    static func decode<T: Decodable>(_ text: String?, marker: String) -> T? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix(marker) else { return nil }
        let base64 = String(raw.dropFirst(marker.count))
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    #if os(iOS)
    @discardableResult
    static func publishConfig(_ payload: GoutouHandoffPayload) -> Bool {
        guard let text = encode(payload, marker: configMarker) else { return false }
        UIPasteboard.general.string = text
        return true
    }

    static func readConfig() -> GoutouHandoffPayload? {
        decode(UIPasteboard.general.string, marker: configMarker)
    }

    /// 云端识图的待确认截图可能接近 4 MB，base64 后更大；超过 2 MB 就不走剪贴板，
    /// 只回一条提示，避免把剪贴板撑爆。
    @discardableResult
    static func publishCapture(_ result: KeyboardCaptureResult, config: AppConfig,
                               relationship: Relationship, secrets: [String: String],
                               profiles: [Relationship] = []) -> Bool {
        var result = result
        if let image = result.screenshot, image.count > 2_000_000 {
            result.screenshot = nil
            result.transcript = ""
            result.error = "截图太大，无法通过剪贴板交给键盘：请把识图方式改成 Apple Vision 本地识别，或用主 App 读取。"
        }
        let envelope = GoutouCaptureEnvelope(result: result, config: config,
                                             relationship: relationship, secrets: secrets,
                                             profiles: profiles, createdAt: Date())
        guard let text = encode(envelope, marker: captureMarker) else { return false }
        UIPasteboard.general.string = text
        return true
    }

    static func readCapture() -> GoutouCaptureEnvelope? {
        decode(UIPasteboard.general.string, marker: captureMarker)
    }
    #endif
}
