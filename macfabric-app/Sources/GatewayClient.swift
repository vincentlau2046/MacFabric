// GatewayClient — 批 1 TOP2 统一网络层（spec 2026-11-17-batch1-auth-network-state.md）
// 规则：admin 调用面单一出口；admin token 与推理 key 双账目隔离；
// born 迁移读一次文件转 Keychain（不每次读盘）；失败如实呈现，绝不假装已配置。
import Foundation

// ── admin token 双账目（service 与推理 key 分离）────────────────

struct AdminTokenCredentialStore {
    static let serviceName = "io.macfabric.gateway-admin"
    private let backing: GatewayCredentialStore

    init(backing: GatewayCredentialStore) { self.backing = backing }

    func load(profile: GatewayProfile) -> String? {
        try? backing.load(profile: profile)
    }

    func save(_ token: String, profile: GatewayProfile) -> Bool {
        do { try backing.save(token, profile: profile); return true }
        catch { return false }
    }
}

extension AdminTokenCredentialStore: GatewayCredentialStore {
    // 显式转发到返回 Bool 的同名重载（避免递归调用 throws 版本）
    func delete(profile: GatewayProfile) throws { try backing.delete(profile: profile) }
    func save(_ key: String, profile: GatewayProfile) throws {
        do { try backing.save(key, profile: profile) } catch { throw CredentialStoreError.denied }
    }
}

// ── born 迁移：读 secrets.env 一次 → 转存凭据库 ────────────────

enum AdminTokenBootstrap: Equatable {
    case migrated          // 文件读到 → 已转存
    case alreadyStored     // 凭据库已有 → 不动
    case absent            // 文件没有 token → 诚实未就绪
    case failed(String)    // 存储拒绝/锁定等 → 如实报错

    /// fileReader 注入便于契约测试；生产实现读档位对应 secrets.env
    /// （prod ~/.inferfabric / dev ~/.inferfabric-dev，跟随状态目录隔离）。
    static func migrate(store: GatewayCredentialStore,
                        fileReader: (GatewayProfile) -> String?,
                        profile: GatewayProfile) -> AdminTokenBootstrap {
        do {
            if try store.load(profile: profile) != nil { return .alreadyStored }
        } catch { return .failed("locked") }
        guard let raw = fileReader(profile), !raw.isEmpty else { return .absent }
        let token = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { line -> String? in
                let l = line.trimmingCharacters(in: .whitespaces)
                guard !l.hasPrefix("#"), l.contains("=") else { return nil }
                let kv = l.split(maxSplits: 1, omittingEmptySubsequences: false,
                                 whereSeparator: { $0 == "=" })
                guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "MACFABRIC_ADMIN_TOKEN"
                else { return nil }
                return kv[1].trimmingCharacters(in: .whitespaces)
            }.first
        guard let token, !token.isEmpty else { return .absent }
        do {
            try store.save(token, profile: profile)
            return .migrated
        } catch CredentialStoreError.denied { return .failed("denied") }
        catch CredentialStoreError.interactionNotAllowed { return .failed("locked") }
        catch { return .failed("error") }
    }

    /// 生产读文件实现：路径随档位（与网关 MACFABRIC_STATE_DIR 口径一致）。
    static func secretsFileReader(profile: GatewayProfile) -> String? {
        let dir = profile == .dev ? "~/.inferfabric-dev" : "~/.inferfabric"
        let path = NSString(string: dir).expandingTildeInPath + "/secrets.env"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// ── admin 请求注入（仅同档位 /admin/* 注 X-Admin-Token）─────────

enum AdminRequestAuthorizer {
    /// 网关控制面路由全集（含非 /admin/ 前缀的顶层动作 — 门禁同源）：
    /// _GET_ROUTES/_POST_ROUTES/_DELETE_ROUTES 里所有套 _admin 门禁的路径。
    static func isControlRoute(_ path: String) -> Bool {
        if path.hasPrefix("/admin/") { return true }
        return ["/switch", "/stop", "/sleep", "/wake", "/reset", "/reconcile",
                "/deploy", "/pull", "/reload-config", "/api/agents",
                "/api/agents/reclassify", "/ocr"].contains(path)
    }

    static func attach(_ request: URLRequest, profile: GatewayProfile, token: String) -> URLRequest {
        var r = request
        guard let url = request.url,
              url.host == "127.0.0.1", url.port == profile.port,
              isControlRoute(url.path) else { return r }
        r.setValue(token, forHTTPHeaderField: "X-Admin-Token")
        return r
    }

    /// 严格版：非同档位 admin 路径抛错（防止 token 带出本机回环）。
    static func authorize(_ request: URLRequest, profile: GatewayProfile, token: String) throws -> URLRequest {
        guard let url = request.url,
              url.host == "127.0.0.1", url.port == profile.port,
              isControlRoute(url.path) else {
            throw CredentialStoreError.denied
        }
        var r = request
        r.setValue(token, forHTTPHeaderField: "X-Admin-Token")
        return r
    }
}

// ── Admin 门禁模式（批 1 语义修订，用户裁决 2026-11-17）──────────

/// 网关控制面鉴权默认关闭、配置即启用（网关侧 MACFABRIC_ADMIN_REQUIRED=1
/// 为严格模式）。App 侧镜像该语义：有 token 就带上（严格模式需要），没有也
/// 放行本机管理动作（默认模式）— API key 是云厂商请求认证，不是软件功能门槛。
enum AdminAuthPolicy {
    static var strictMode: Bool {
        ProcessInfo.processInfo.environment["MACFABRIC_ADMIN_REQUIRED"] != nil
    }
}

// ── 错误分类 + 代际防乱序 ───────────────────────────────────────

enum GatewayClientError: Equatable {
    case offline          // 连接失败/超时（网关不可达）
    case unauthorized     // 401（token 缺失/失效）
    case http(Int)        // 其它 HTTP 错误
    case malformed        // 2xx 但 body 不可解析

    static func from(status: Int) -> GatewayClientError {
        status == 401 ? .unauthorized : .http(status)
    }
}

struct GenerationGuard {
    private(set) var maxGeneration = 0

    mutating func bump() { maxGeneration += 1 }

    /// 旧代际响应丢弃（防旧响应覆盖新选择）；同代或更新接受。
    mutating func accept(_ generation: Int) -> Bool {
        guard generation >= maxGeneration else { return false }
        maxGeneration = generation
        return true
    }
}

// ── 批 3：试聊流式三件套（纯函数，契约测试钉住）────────────────

/// SSE data: 帧增量解析 — 只关心 chat.completions 的 delta.content。
enum SSEParser {
    struct Event: Equatable {
        var delta: String?   // 增量正文（无正文帧为 nil）
        var done: Bool       // data: [DONE]
    }

    /// 输入一行原始 SSE 文本（已去行尾换行）；非 data: 行忽略。
    static func parse(line: String) -> Event {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return Event(delta: nil, done: false) }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return Event(delta: nil, done: true) }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]] else { return Event(delta: nil, done: false) }
        // 兼容 role-only 首帧 / delta 缺失 / usage 尾帧
        guard let delta = choices.first?["delta"] as? [String: Any] else { return Event(delta: nil, done: false) }
        return Event(delta: delta["content"] as? String, done: false)
    }
}

/// 试聊目标模型选择 — 只认活跃 LLM，绝不回退嵌入/首个任意模型。
enum ChatTargetPicker {
    static func pick(activeLLMs: [String], preferred: String?) -> String? {
        if let preferred, activeLLMs.contains(preferred) { return preferred }
        return activeLLMs.first
    }
}

/// 停止收尾 — 已到部分如实保留 + 标注；空则诚实说没收到内容。
enum ChatStop {
    static func finalText(_ partial: String) -> String {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（已停止 — 未收到内容）" : partial + "\n\n（已停止 — 部分回复）"
    }
}

// ── 批 4：控制面长任务轮询纯函数（spec 2026-11-17-batch4-jobs-infra.md）──

/// job 轮询终态判定：未知/未终态继续轮询；终态如实分类；超时独立成档
/// （网关侧可能仍在跑 — App 停止轮询但不谎报失败）。
enum JobCompletion: Equatable {
    case keepPolling, succeeded, failed, cancelled, timedOut

    static func evaluate(_ job: [String: Any]?, elapsed: TimeInterval, timeout: TimeInterval) -> JobCompletion {
        guard let status = job?["status"] as? String, !status.isEmpty else {
            return .keepPolling
        }
        switch status {
        case "done": return .succeeded
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return elapsed >= timeout ? .timedOut : .keepPolling
        }
    }
}
