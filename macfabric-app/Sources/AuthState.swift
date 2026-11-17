// 鉴权状态机 + 网关档位 + 凭据存取协议 + 推理请求注入（plan B2 接口）
// 规则：5xx/畸形/超时 ≠ 未启用；失败时 lastGood 标 stale；旧代际响应忽略；
// 仅向匹配档位的推理路径注 Bearer；跨源重定向丢弃请求，密钥不外带。
import Foundation

// ── 网关档位（loopback 固定 origin）─────────────────────────────

enum GatewayProfile: String, CaseIterable, Equatable {
    case dev, prod

    var port: Int { self == .dev ? 8998 : 8999 }
    var origin: String { "http://127.0.0.1:\(port)" }

    /// Keychain account 隔离：`<profile>|<origin>`；dev 绝不读 prod 账目。
    var keychainAccount: String { "\(rawValue)|\(origin)" }
    static let keychainService = "io.macfabric.gateway-api-key"
}

// ── 鉴权快照与状态机 ────────────────────────────────────────────

struct SecuritySnapshot: Equatable {
    let policy: String?
    let active: Bool
    let enforced: Bool
    let fetchedAt: Date

    var presentation: AuthPresentation {
        AuthPresentation.present(policy: policy, gatewayUp: true, fetched: true)
    }
}

enum SecurityState: Equatable {
    case loading
    case loaded(SecuritySnapshot, stale: Bool)
    case unavailable
}

enum StatusFetchError: Error, Equatable {
    case http(Int)
    case malformed
    case timeout
    case transport
}

enum SecurityGatewayStatus {
    /// 成功快照 = HTTP 2xx 且 JSON 可解析；其余一律 nil（由调用方折为 failure）。
    static func parse(data: Data?, response: URLResponse?, error: Error?) -> SecuritySnapshot? {
        if let error {
            if (error as NSError).code == NSURLErrorTimedOut { return nil }
            return nil
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let data else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let policy = obj["policy"] as? String
        let active = obj["active"] as? Bool ?? false
        let enforced = obj["enforced"] as? Bool ?? false
        return SecuritySnapshot(policy: policy, active: active, enforced: enforced, fetchedAt: Date())
    }
}

/// 状态请求代际机：gen 小于已见最大值 → 忽略（防旧 profile 响应覆盖新 profile）。
/// 失败：有 lastGood → .loaded(lastGood, stale: true)；无 → .unavailable。绝不派生"未启用"。
struct SecurityStatusStore {
    private(set) var state: SecurityState = .loading
    private(set) var snapshot: SecuritySnapshot?
    private var maxGeneration = 0

    mutating func apply(_ generation: Int, _ outcome: Result<SecuritySnapshot, StatusFetchError>) {
        guard generation >= maxGeneration else { return }
        maxGeneration = generation
        switch outcome {
        case .success(let snap):
            snapshot = snap
            state = .loaded(snap, stale: false)
        case .failure:
            if let last = snapshot {
                state = .loaded(last, stale: true)
            } else {
                state = .unavailable
            }
        }
    }
}

// ── 凭据存取协议（真实 Keychain 实现在 GatewayKeychain.swift）───

enum CredentialStoreError: Error, Equatable {
    case denied
    case interactionNotAllowed
    case unavailable
}

protocol GatewayCredentialStore {
    mutating func load(profile: GatewayProfile) throws -> String?
    mutating func save(_ key: String, profile: GatewayProfile) throws
    mutating func delete(profile: GatewayProfile) throws
}

/// 录入流程结果：失败如实报 failed，绝不声称“已保存”。
enum CredentialOutcome: Equatable {
    case saved
    case failed(String)
}

enum CredentialFlow {
    static func record(store: GatewayCredentialStore, profile: GatewayProfile, key: String) -> CredentialOutcome {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("empty") }
        do {
            var s = store
            try s.save(trimmed, profile: profile)
            return .saved
        } catch CredentialStoreError.denied { return .failed("denied") }
        catch CredentialStoreError.interactionNotAllowed { return .failed("locked") }
        catch { return .failed("error") }
    }
}

// ── 推理请求注入 ────────────────────────────────────────────────

enum InferenceRequestAuthorizer {
    /// 管理端点/静态资产不注入；仅同档位 origin 的推理路径注入 Bearer。
    private static func isInferrerPath(_ url: URL) -> Bool {
        let p = url.path
        return p.hasPrefix("/v1/") || p == "/ocr"
    }

    static func authorize(_ request: URLRequest, profile: GatewayProfile, key: String) throws -> URLRequest {
        guard let url = request.url else { throw CredentialStoreError.unavailable }
        guard url.host == "127.0.0.1", url.port == profile.port, isInferrerPath(url) else {
            throw CredentialStoreError.denied
        }
        var r = request
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// 跟随重定向前的核验：跨源（不同 host/port）→ 丢弃请求，密钥不外带。
    static func redirectAllowed(from: URL, to: URL, profile: GatewayProfile) -> Bool {
        guard let f = from.host, let t = to.host else { return false }
        return f == t && from.port == to.port && to.port == profile.port
    }
}
