// Admin Token 本机文件存取（用户裁决 2026-11-18：默认模式零钥匙串触碰）。
// 背景：adhoc 重新构建后 macOS 视新签名为陌生程序，登录钥匙串每次发版
// 重新弹授权密码框，3 秒轮询放大为反复抢占 — 钥匙串不适配本发布流程。
// 路径：~/Library/Application Support/MacFabric/admin-token-<profile>.token
// 权限：目录 0700 + 文件 0600（仅当前用户可读），写入先写临时文件再原子替换。
import Foundation

struct FileCredentialStore: GatewayCredentialStore {
    private let directoryPath: String

    init(directoryPath: String? = nil) {
        if let directoryPath {
            self.directoryPath = directoryPath
        } else {
            let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                ?? (NSHomeDirectory() + "/Library/Application Support")
            self.directoryPath = base + "/MacFabric"
        }
    }

    private func filePath(_ profile: GatewayProfile) -> String {
        directoryPath + "/admin-token-\(profile.rawValue).token"
    }

    func load(profile: GatewayProfile) throws -> String? {
        let path = filePath(profile)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path),
              let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.denied
        }
        return value
    }

    func save(_ key: String, profile: GatewayProfile) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: directoryPath, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let target = filePath(profile)
        let tmp = directoryPath + "/.admin-token-\(profile.rawValue).tmp"
        if fm.fileExists(atPath: tmp) {
            try? fm.removeItem(atPath: tmp)
        }
        guard fm.createFile(atPath: tmp, contents: Data(key.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            throw CredentialStoreError.denied
        }
        if fm.fileExists(atPath: target) {
            try fm.removeItem(atPath: target)
        }
        try fm.moveItem(atPath: tmp, toPath: target)
    }

    func delete(profile: GatewayProfile) throws {
        let path = filePath(profile)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw CredentialStoreError.denied
        }
    }
}
