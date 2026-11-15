// MacFabric 原生 App — P2（照 design/ui-design-v0.html 织物语言实现）
// 无 Xcode / 无 SwiftUI 宏（CLT 缺 SwiftUIMacros 插件）：
// AppKit 引导（NSStatusItem + NSWindow）+ NSHostingView 承载 SwiftUI；
// 状态集中 ObservableObject，手动 Binding。
import SwiftUI
import Charts
import Combine
import AppKit

// ─── 设计 token（design/ui-design-v0.html :root）────────────────

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
    static let desk = Color(hex: 0xf5f5f8)      // 桌面（light 默认 — 用户偏好）
    static let panel = Color(hex: 0xffffff)     // 窗口面板
    static let chrome = Color(hex: 0xececf1)    // 标题栏
    static let glass = Color.black.opacity(0.045)
    static let lineC = Color.black.opacity(0.10)
    static let ink = Color(hex: 0x1d1d22)
    static let dim = Color(hex: 0x55555f)
    static let faint = Color(hex: 0x85858f)
    static let accent = Color(hex: 0x4a63e8)    // 织物蓝
    static let okC = Color(hex: 0x1fa843)
    static let warnC = Color(hex: 0xb06000)
    // 能力线色（九根线 = 九类能力）
    static let thJudge = Color(hex: 0x8e4fd8)
    static let thLlm = Color(hex: 0x4c5fe0)
    static let thVl = Color(hex: 0xe0508b)
    static let thEmb = Color(hex: 0x0f9c77)
    static let thRerank = Color(hex: 0x2b7fd4)
    static let thAsr = Color(hex: 0xc78a1f)
    static let thTts = Color(hex: 0xd45f35)
    static let thOcr = Color(hex: 0x6b9c1f)
    static let thImg = Color(hex: 0x1c9fa0)
}

/// 能力线色 + 人话名（设计稿：能力名用人话说，模型真名放小字）
func threadColor(_ modelType: String?) -> Color {
    switch modelType {
    case "llm": return .thLlm
    case "vl": return .thVl
    case "embedding": return .thEmb
    case "rerank": return .thRerank
    case "asr": return .thAsr
    case "tts": return .thTts
    case "ocr": return .thOcr
    case "aigc": return .thImg
    default: return .thLlm
    }
}
func humanName(_ modelType: String?) -> String {
    switch modelType {
    case "llm": return "对话"
    case "vl": return "看图"
    case "embedding": return "嵌入"
    case "rerank": return "重排"
    case "asr": return "语音转写"
    case "tts": return "语音合成"
    case "ocr": return "文字识别"
    case "aigc": return "生图"
    default: return "对话"
    }
}

// ─── 数据模型 ──────────────────────────────────────────────────

struct Snapshot: Codable {
    struct Status: Codable {
        var gpu_mode: String?
        var active_services: [String]?
        var services_health: [String: String]?
        var services_info: [String: ServiceInfo]?
        var gpu_used_mb: Int?
        var gpu_total_mb: Int?
        var sleep_states: [String: String]?
    }
    struct ServiceInfo: Codable {
        var mode: String?
        var type: String?
        var port: Int?
    }
    var status: Status
}

struct ModelItem: Codable {
    var name: String
    var description: String?
    var mode: String?
    var type: String?
    var model_type: String?
    var active: Bool?
    var context_window: Int?
    var peak_vram_mb: Int?
    var ledger_mode: String?
    var autostart: Bool?
    var anthropic_native: Bool?
    var ledgerMode: String { ledger_mode ?? "on_demand" }
}

struct CurvePoint: Codable {
    var t: Double
    var tokens: Int
    var requests: Int
}

// ── 安装版/调试版分离：bundle 含 DEV_PROFILE 标记（build.sh --debug 写入）
// → 调试档网关 :8998（scripts/dev-gateway.sh，状态 ~/.inferfabric-dev）；
//   正式档 :8999（/Applications/MacFabric.app，状态 ~/.inferfabric）
let IS_DEV_PROFILE = Bundle.main.url(forResource: "DEV_PROFILE", withExtension: nil) != nil
let GW_PORT = IS_DEV_PROFILE ? 8998 : 8999
let GW_BASE = "http://127.0.0.1:\(GW_PORT)"

struct PoolCandidate: Codable {
    var id: String
    var priority: Int
    var kind: String?
    var target: String?
    /// 行身份含内容 — 换模型后 target 变化强制 SwiftUI 重渲染该行（防 diffing 陈旧）
    var rowKey: String { "\(id)|\(target ?? "")|\(kind ?? "")|\(priority)" }
}
struct PoolDef: Codable {
    var enabled: Bool?
    var candidates: [PoolCandidate]?
}
struct PoolsPayload: Codable {
    var revision: Int
    var pools: [String: PoolDef]?
}
struct CloudModelSpec: Codable {
    var id: String
    var manual: Bool?
    var supports_vision: Bool?
    var supports_tools: Bool?
    var context_window: Int?      // 理论最大上下文（属性浮窗编辑）
    var max_output_tokens: Int?   // 理论最大输出
    var price_input: Double?      // ¥/1M tokens
    var price_output: Double?
    var anthropic: Bool?          // 注册表 anthropic_available（非 spec 原生字段，运行时合成）
}
struct CloudProvider: Codable {
    var name: String
    var enabled: Bool?
    var openai_base: String?
    var anthropic_base: String?
    var discovery_enabled: Bool?
    var enabled_models: [String]?
    var model_specs: [CloudModelSpec]?
    var routable_count: Int?
    var key_env_set: Bool?
}
struct CloudPayload: Codable {
    var providers: [CloudProvider]?
    var total_cloud_models: Int?
    var models: [CloudModelInfo]?
}
struct CloudModelInfo: Codable {
    var id: String
    var provider: String?
    var openai_available: Bool?
    var anthropic_available: Bool?
}
struct LocalDiscovered: Codable {
    var name: String
    var type: String?
    var framework: String?
    var size_mb: Int?
}
struct LocalModelsPayload: Codable {
    var discovered: [LocalDiscovered]?
    var configured: [String]?
}
struct PackDownloadState: Codable {
    var status: String?
    var downloaded: Int?
    var total: Int?
    var error: String?
    var detail: String?      // 引擎构建阶段文案（"cmake 配置…"/"编译中…"）
}
struct SecurityKeyInfo: Identifiable {
    let id: String
    let name: String
    let createdAt: Double?
    let revoked: Bool
}
struct ModelMetrics: Codable {
    var requests: Int?
    var success: Int?
    var fail: Int?
    var tokens_in: Int?
    var tokens_out: Int?
    var cost_yuan: Double?
    var source: String?
    var ttft_p50: Double?
    var ttft_p95: Double?
    var e2e_tps_p50: Double?
    var duration_p95: Double?
}
struct MetricsPayload: Codable {
    var window: String?
    var total_requests: Int?
    var success: Int?
    var fail: Int?
    var models: [String: ModelMetrics]?
}

final class GatewayStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var gatewayUp = false
    @Published var tab = 0
    @Published var prompt = "你好，介绍一下你自己"
    @Published var reply = ""
    @Published var busy = false
    @Published var models: [ModelItem] = []
    @Published var curve: [CurvePoint] = []
    /// 操作反馈横幅 — 5s 自动消退（陈旧的 ✅/❌ 长期挂在卡片上误导）
    @Published var actionMessage = "" {
        didSet {
            guard !actionMessage.isEmpty else { return }
            msgClear?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.actionMessage = "" }
            msgClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }
    private var msgClear: DispatchWorkItem?
    @Published var hubExpanded = ""
    @Published var pools: PoolsPayload?
    /// 待确认卸载的能力包名 — 6s 未确认自动复位（两击确认不残留）
    @Published var uninstallConfirm: String? = nil {
        didSet {
            confirmResetPack?.cancel(); confirmResetPack = nil
            guard uninstallConfirm != nil else { return }   // 手动复位/超时回 nil 时不排程
            let work = DispatchWorkItem { [weak self] in self?.confirmResetPack = nil
                                          self?.uninstallConfirm = nil }
            confirmResetPack = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }
    // 全局确认弹窗（SwiftUI confirmationDialog；action 在用户确认后执行）
    @Published var confirmText: String? = nil
    @Published var confirmAction: (() -> Void)? = nil

    func confirm(_ text: String, _ action: @escaping () -> Void) {
        confirmText = text
        confirmAction = action
    }
    // F3: 云端接入 CRUD 状态
    @Published var cloud: CloudPayload?
    @Published var cloudExpanded: String? = nil
    /// 待确认删除的服务商名 — 同款 6s 自动复位
    @Published var cloudDeleteConfirm: String? = nil {
        didSet {
            confirmResetProvider?.cancel(); confirmResetProvider = nil
            guard cloudDeleteConfirm != nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.confirmResetProvider = nil
                                          self?.cloudDeleteConfirm = nil }
            confirmResetProvider = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }
    private var confirmResetPack: DispatchWorkItem?
    private var confirmResetProvider: DispatchWorkItem?
    @Published var cloudFormName = ""
    @Published var cloudFormBase = ""
    @Published var cloudFormKey = ""
    @Published var cloudFormAnth = ""
    @Published var cloudAddModel = ""
    // F4: 本地模型发现/安装
    @Published var localDiscovered: [LocalDiscovered] = []
    @Published var localScanned = false
    // G4: 监控台 per-model 指标
    @Published var metrics: MetricsPayload?
    // 能力包下载进度（键 = 模型名）
    @Published var packDownloads: [String: PackDownloadState] = [:]
    // ── API Key 鉴权（设置页接线 — /admin/security/*）──
    @Published var securityEnforced = false
    @Published var securityKeyCount = 0
    @Published var securityBusy = false
    @Published var oneTimeKey: String? = nil   // 首次启用/新建返回的明文 key（仅此一次，库内只存摘要）
    @Published var securityKeys: [SecurityKeyInfo] = []
    @Published var securityKeyRevokeConfirm: String? = nil {
        didSet {
            confirmResetSecKey?.cancel()
            guard securityKeyRevokeConfirm != nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.securityKeyRevokeConfirm = nil }
            confirmResetSecKey = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }
    private var confirmResetSecKey: DispatchWorkItem?
    var onMemoryInsufficient: ((_ name: String, _ reason: String) -> Void)?

    private var base: URL { URL(string: GW_BASE)! }
    private var timer: Timer?
    private var curveTimer: Timer?
    /// 主窗口可见性 — 菜单栏常驻应用，窗口关闭后暂停轮询（空转打点无意义；
    /// 菜单栏迷你条是独立 store，打开菜单时刷新一次）
    var windowVisible = true

    init() {
        refresh(); fetchModels(); fetchCurve(); fetchPools(); fetchCloud(); scanLocalModels(); fetchMetrics(); fetchSecurityStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.windowVisible else { return }
            self.refresh(); self.fetchModels(); self.fetchDownloadStatus(); self.fetchSecurityStatus()
            self.fetchPools()   // 池可能被其它页面/服务端联动改变（如卸载触发的候选清除）
        }
        curveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.windowVisible else { return }
            self.fetchCurve(); self.fetchCloud()   // 云端发现/注册表周期性变化
        }
    }

    func refresh() {
        var req = URLRequest(url: base.appendingPathComponent("/api/snapshot"), timeoutInterval: 3)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let data, let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                    self.snapshot = snap; self.gatewayUp = true
                } else { self.gatewayUp = false }
            }
        }.resume()
    }

    func fetchModels() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/models")) { [weak self] data, _, _ in
            guard let self, let data,
                  let list = try? JSONDecoder().decode([ModelItem].self, from: data) else { return }
            DispatchQueue.main.async { self.models = list }
        }.resume()
    }

    func fetchPools() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/admin/model-pools")) { [weak self] data, _, _ in
            guard let self, let data,
                  let pl = try? JSONDecoder().decode(PoolsPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.pools = pl }
        }.resume()
    }

    /// F1: 候选操作统一入口 — 每次现取 raw（旧版缓存导致网关重启后 ↑↓ 静默失效）。
    /// mutate(raw) 在后台线程改 priorities/candidates，POST CAS 回写。
    /// 409（连点/竞态）自动以新 revision 重放一次同一语义操作，不丢点击。
    func mutatePools(_ mutate: @escaping (inout [String: Any]) -> Void,
                     okMsg: String, failPrefix: String) {
        postPoolsMutation(mutate, okMsg: okMsg, failPrefix: failPrefix, allowRetry: true)
    }

    private func postPoolsMutation(_ mutate: @escaping (inout [String: Any]) -> Void,
                                   okMsg: String, failPrefix: String, allowRetry: Bool) {
        guard let url = URL(string: "\(GW_BASE)/admin/model-pools") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var raw = obj["raw"] as? [String: Any],
                  let rev = obj["revision"] as? Int else {
                DispatchQueue.main.async { self?.actionMessage = "❌ 池配置读取失败" }
                return
            }
            mutate(&raw)
            raw["expected_revision"] = rev
            var req = URLRequest(url: url, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: raw)
            URLSession.shared.dataTask(with: req) { [weak self] data2, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = data2.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    if code == 409 && allowRetry {
                        // revision 过期（连点/与轮询竞态）— 取新基点重放同一语义，不报错不丢点击
                        self?.postPoolsMutation(mutate, okMsg: okMsg, failPrefix: failPrefix, allowRetry: false)
                        return
                    }
                    self?.actionMessage = (200..<300).contains(code)
                        ? okMsg : "❌ \(failPrefix)(\(code)): \(body.prefix(100))"
                    self?.fetchPools()
                }
            }.resume()
        }.resume()
    }

    /// 乐观排序：本地 pools 立即重排（UI 零延迟），CAS 回写在后台；
    /// 失败时 fetchPools 以服务端真相自动回滚显示。
    private func applyLocalPoolOrder(_ pool: String, reorder: (inout [PoolCandidate]) -> Void) {
        guard var pl = pools, var cfg = pl.pools, var cands = cfg[pool]?.candidates, !cands.isEmpty else { return }
        cands.sort { $0.priority < $1.priority }
        reorder(&cands)
        for i in cands.indices { cands[i].priority = i * 10 }
        cfg[pool]?.candidates = cands
        pl.pools = cfg
        pools = pl
    }

    /// F1: 候选优先级上移/下移 — 交换位置后**全量重建 priority = index*10**。
    /// （旧实现交换相邻 priority 值：两候选同 priority 时交换后数值不变，
    /// 是 UI 零反馈的静默 no-op — 用户实测报障；重复 priority 本身也是服务端
    /// 校验拒绝项，重建顺带治好存量脏数据）
    func reorderCandidate(pool: String, candidateId: String, up: Bool) {
        // 乐观：本地立即换位
        applyLocalPoolOrder(pool) { cands in
            guard let idx = cands.firstIndex(where: { $0.id == candidateId }) else { return }
            let swap = up ? idx - 1 : idx + 1
            guard cands.indices.contains(swap) else { return }
            cands.swapAt(idx, swap)
        }
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var poolCfg = poolsCfg[pool] as? [String: Any],
                  var cands = poolCfg["candidates"] as? [[String: Any]] else { return }
            cands.sort { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }
            guard let idx = cands.firstIndex(where: { $0["id"] as? String == candidateId }) else { return }
            let swap = up ? idx - 1 : idx + 1
            guard cands.indices.contains(swap) else { return }
            cands.swapAt(idx, swap)
            for (i, _) in cands.enumerated() { cands[i]["priority"] = i * 10 }
            poolCfg["candidates"] = cands
            poolsCfg[pool] = poolCfg
            raw["pools"] = poolsCfg
        }, okMsg: "✅ 优先级已更新", failPrefix: "排序失败")
    }

    // ── 池候选拖拽排序（onDrag/onDrop；拖拽中候选 id）──
    @Published var poolDragging: String? = nil

    /// 拖拽落点：dragged 移动到 target 位置，全量重建 priority = index*10（CAS 回写）
    func moveCandidate(pool: String, dragged: String, target: String) {
        guard dragged != target else { return }
        // 乐观：本地立即移位
        applyLocalPoolOrder(pool) { cands in
            guard let from = cands.firstIndex(where: { $0.id == dragged }),
                  let to = cands.firstIndex(where: { $0.id == target }) else { return }
            let item = cands.remove(at: from)
            cands.insert(item, at: to)
        }
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var poolCfg = poolsCfg[pool] as? [String: Any],
                  var cands = poolCfg["candidates"] as? [[String: Any]] else { return }
            cands.sort { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }
            guard let from = cands.firstIndex(where: { $0["id"] as? String == dragged }),
                  let to = cands.firstIndex(where: { $0["id"] as? String == target }) else { return }
            let item = cands.remove(at: from)
            cands.insert(item, at: to)
            for (i, _) in cands.enumerated() { cands[i]["priority"] = i * 10 }
            poolCfg["candidates"] = cands
            poolsCfg[pool] = poolCfg
            raw["pools"] = poolsCfg
        }, okMsg: "✅ 顺序已更新", failPrefix: "拖拽排序失败")
    }

    /// 池候选换模型（target 替换；local → model_name，cloud → provider+model_id。
    /// 候选 id 保留原值 — 身份稳定，evidence/历史不悬空）
    func replacePoolCandidate(pool: String, candidateId: String, to target: String, kind: String) {
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var poolCfg = poolsCfg[pool] as? [String: Any],
                  var cands = poolCfg["candidates"] as? [[String: Any]] else { return }
            guard let idx = cands.firstIndex(where: { $0["id"] as? String == candidateId }) else { return }
            var cand = cands[idx]
            cand["kind"] = kind
            if kind == "cloud" {
                // target = "provider/model"；provider 不含 "/"（model_id 可含，切第一段）
                let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                cand["provider"] = parts[0]
                cand["model_id"] = parts[1]
                cand.removeValue(forKey: "model_name")
            } else {
                cand["model_name"] = target
                cand.removeValue(forKey: "provider")
                cand.removeValue(forKey: "model_id")
            }
            cands[idx] = cand
            poolCfg["candidates"] = cands
            poolsCfg[pool] = poolCfg
            raw["pools"] = poolsCfg
        }, okMsg: "✅ 候选已换为 \(target)", failPrefix: "换候选失败")
    }

    /// 池候选移除
    func removePoolCandidate(pool: String, candidateId: String) {
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var poolCfg = poolsCfg[pool] as? [String: Any],
                  var cands = poolCfg["candidates"] as? [[String: Any]] else { return }
            cands.removeAll { $0["id"] as? String == candidateId }
            poolCfg["candidates"] = cands
            poolsCfg[pool] = poolCfg
            raw["pools"] = poolsCfg
        }, okMsg: "✅ 候选已移除", failPrefix: "移除失败")
    }

    /// 池候选追加（schema 正确：cloud 必须 provider+model_id — 修复
    /// "cloud candidate requires provider" 400；id 唯一化防碰撞）
    func addPoolCandidate(pool: String, target: String, kind: String) {
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var poolCfg = poolsCfg[pool] as? [String: Any],
                  var cands = poolCfg["candidates"] as? [[String: Any]] else { return }
            let maxPrio = cands.map { $0["priority"] as? Int ?? 0 }.max() ?? 0
            let baseId = kind == "cloud"
                ? target.replacingOccurrences(of: "/", with: "_")
                : target
            var cid = baseId
            var n = 2
            while cands.contains(where: { ($0["id"] as? String) == cid }) {
                cid = "\(baseId)-\(n)"; n += 1
            }
            var cand: [String: Any] = ["id": cid, "kind": kind, "priority": maxPrio + 10]
            if kind == "cloud" {
                let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                cand["provider"] = parts[0]
                cand["model_id"] = parts[1]
            } else {
                cand["model_name"] = target
            }
            cands.append(cand)
            poolCfg["candidates"] = cands
            poolsCfg[pool] = poolCfg
            raw["pools"] = poolsCfg
        }, okMsg: "✅ 已加候选 \(target)", failPrefix: "加候选失败")
    }

    /// F8: 单池 enabled 开关（服务端字段级原子修改 + expected_revision CAS）
    func togglePool(_ name: String, enabled: Bool) {
        guard let rev = pools?.revision else { return }
        var req = URLRequest(url: base.appendingPathComponent("/admin/model-pools/toggle"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pool": name, "enabled": enabled, "expected_revision": rev])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.actionMessage = (200..<300).contains(code)
                    ? "✅ iff/\(name) 已\(enabled ? "启用" : "停用")" : "❌ 开关失败(\(code)): \(body.prefix(100))"
                self?.fetchPools()
            }
        }.resume()
    }

    /// F2: 能力包卸载 = 停服务 + 删 models.d YAML + 热重载
    func uninstallPack(_ name: String) {
        actionMessage = "卸载 \(name) 中…"
        var req = URLRequest(url: base.appendingPathComponent("/admin/packs/uninstall"), timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.actionMessage = (200..<300).contains(code)
                    ? "✅ \(name) 已卸载" : "❌ 卸载失败(\(code)): \(body.prefix(120))"
                // 卸载是跨页面事件：模型列表、池（服务端已联动清除候选）、
                // 本地扫描、下载状态全部即时刷新 — 不等轮询、不用切页面
                self?.fetchModels(); self?.fetchPools()
                self?.scanLocalModels(); self?.fetchDownloadStatus()
            }
        }.resume()
    }

    func fetchCloud() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/admin/cloud/providers")) { [weak self] data, _, _ in
            guard let self, let data,
                  let cp = try? JSONDecoder().decode(CloudPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.cloud = cp }
        }.resume()
    }

    /// 设置页：鉴权开关状态（30s 轮询 + 操作后即时刷新）
    func fetchSecurityStatus() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/admin/security/status")) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.securityEnforced = obj["enforced"] as? Bool ?? false
                let keys = (obj["keys"] as? [[String: Any]] ?? []).compactMap {
                    SecurityKeyInfo(id: $0["id"] as? String ?? "",
                                    name: $0["name"] as? String ?? "?",
                                    createdAt: $0["created_at"] as? Double,
                                    revoked: $0["revoked"] as? Bool ?? false)
                }
                self.securityKeys = keys
                self.securityKeyCount = obj["key_count"] as? Int ?? keys.filter { !$0.revoked }.count
            }
        }.resume()
    }

    /// 设置页：新建 API key（明文仅本次回显 — 立即弹一次性复制面板）
    func createSecurityKey() {
        guard !securityBusy else { actionMessage = "⚠️ 上一操作进行中，请稍候"; return }
        securityBusy = true
        var req = URLRequest(url: base.appendingPathComponent("/admin/security/keys"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": "macfabric-app"])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.securityBusy = false
                if (200..<300).contains(code),
                   let obj = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                   let key = obj["key"] as? String, !key.isEmpty {
                    self.oneTimeKey = key
                    self.actionMessage = "✅ 新密钥已生成 — 明文仅显示这一次，请立即复制"
                } else {
                    self.actionMessage = "❌ 新建密钥失败(\(code)): \(raw.prefix(100))"
                }
                self.fetchSecurityStatus()
            }
        }.resume()
    }

    /// 设置页：撤销指定 key（两击确认）
    func revokeSecurityKey(_ id: String) {
        guard !securityBusy else { actionMessage = "⚠️ 上一操作进行中，请稍候"; return }
        securityBusy = true
        var req = URLRequest(url: base.appendingPathComponent("/admin/security/keys/revoke"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.securityBusy = false
                self.actionMessage = (200..<300).contains(code)
                    ? "✅ 密钥已撤销" : "❌ 撤销失败(\(code))"
                self.securityKeyRevokeConfirm = nil
                self.fetchSecurityStatus()
            }
        }.resume()
    }

    /// 设置页：一键启用/关闭鉴权。启用时网关返回的首把明文 key 存 oneTimeKey
    /// （库内只存摘要 — 不弹这次就再也拿不到明文）。
    func toggleSecurity(_ enable: Bool) {
        guard !securityBusy else { actionMessage = "⚠️ 上一操作进行中，请稍候"; return }
        securityBusy = true
        var req = URLRequest(url: base.appendingPathComponent("/admin/security/enable"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["enforce": enable])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.securityBusy = false
                if (200..<300).contains(code) {
                    self.actionMessage = enable ? "✅ 鉴权已启用 — 客户端请求需携带 API Key"
                                                : "✅ 鉴权已关闭（迁移宽限，密钥保留）"
                    if enable,
                       let obj = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                       let key = obj["key"] as? String, !key.isEmpty {
                        self.oneTimeKey = key
                    }
                } else {
                    self.actionMessage = "❌ 鉴权设置失败(\(code)): \(raw.prefix(100))"
                }
                self.fetchSecurityStatus()
            }
        }.resume()
    }

    /// F3: 添加服务商（name + openai_base + api_key；key 写 secrets.env，YAML 只存 ${REF}）
    func addCloudProvider() {
        let name = cloudFormName.trimmingCharacters(in: .whitespaces)
        let burl = cloudFormBase.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !burl.isEmpty else {
            actionMessage = "⚠️ 名称与 Base URL 必填"; return
        }
        var body: [String: Any] = ["name": name, "openai_base": burl, "discovery_enabled": true]
        let aburl = cloudFormAnth.trimmingCharacters(in: .whitespaces)
        if !aburl.isEmpty { body["anthropic_base"] = aburl }   // 原生 Anthropic 直连（可选）
        let key = cloudFormKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { body["api_key"] = key }
        cloudRequest(path: "/admin/cloud/providers", method: "POST", body: body,
                     okMsg: "✅ 服务商 \(name) 已添加", failPrefix: "添加失败")
    }

    /// F3: 删除服务商（两击确认）
    func deleteCloudProvider(_ name: String) {
        cloudRequest(path: "/admin/cloud/providers", method: "DELETE", body: ["name": name],
                     okMsg: "✅ 服务商 \(name) 已删除", failPrefix: "删除失败")
    }

    /// F3: 触发全量模型发现（provider 侧 /models 端点；服务端串行抓取可达
    /// 分钟级 — App 超时须放宽，否则显示失败但服务端仍在跑）
    func cloudDiscover() {
        cloudRequest(path: "/admin/cloud/discover", method: "POST", body: [:],
                     okMsg: "✅ 发现完成 — 列表已更新", failPrefix: "发现失败", timeout: 150)
    }

    /// F3: 模型策展 — enable/disable（勾选）/add（手填）/remove/tag（VL 打标）
    /// extra: 属性浮窗扩展键（context_window/max_output_tokens/price_input/price_output；
    /// NSNull = 清除属性 — JSON null 直通网关清除语义）
    func cloudModelAction(_ provider: String, action: String, model: String,
                          vision: Bool? = nil, tools: Bool? = nil,
                          extra: [String: Any]? = nil) {
        var body: [String: Any] = ["provider": provider, "action": action, "model": model]
        if let v = vision { body["supports_vision"] = v }
        if let t = tools { body["supports_tools"] = t }
        if let e = extra { for (k, val) in e { body[k] = val } }
        cloudRequest(path: "/admin/cloud/provider-models", method: "POST", body: body,
                     okMsg: "✅ \(model) · \(action) 成功", failPrefix: "\(model) \(action) 失败")
    }

    // ── 云端模型属性浮窗（点击模型行 → 配置属性/单独删除）──
    @Published var cloudEditorProvider: String? = nil
    @Published var cloudEditorSpec: CloudModelSpec? = nil
    @Published var cloudEditorEnabled: Bool = false
    // 浮窗草稿 — 表单绑定走 store（CLT 无 SwiftUI 宏插件，视图内 @State 不可用）
    @Published var editorVision = false
    @Published var editorTools = false
    @Published var editorCtx = ""
    @Published var editorOut = ""
    @Published var editorPriceIn = ""
    @Published var editorPriceOut = ""
    @Published var editorConfirmDelete = false

    func openCloudModelEditor(provider: String, spec: CloudModelSpec, enabled: Bool) {
        cloudEditorProvider = provider
        cloudEditorSpec = spec
        cloudEditorEnabled = enabled
        editorVision = spec.supports_vision == true
        editorTools = spec.supports_tools == true
        editorCtx = spec.context_window.map { String($0) } ?? ""
        editorOut = spec.max_output_tokens.map { String($0) } ?? ""
        editorPriceIn = (spec.price_input ?? 0) > 0 ? String(format: "%g", spec.price_input!) : ""
        editorPriceOut = (spec.price_output ?? 0) > 0 ? String(format: "%g", spec.price_output!) : ""
        editorConfirmDelete = false
    }

    func closeCloudModelEditor() {
        cloudEditorProvider = nil
        cloudEditorSpec = nil
        editorConfirmDelete = false
    }

    /// 浮窗保存 = 一次 tag 请求落全部字段（能力 + 属性；NSNull = 清除）。
    /// 启用/停用不在此混发 — 云请求防抖下第二个请求会被拒，勾选仍在行内按钮。
    func saveCloudModelEditor() {
        guard let provider = cloudEditorProvider, let spec = cloudEditorSpec else { return }
        var extra: [String: Any] = [:]
        let ctx = editorCtx.trimmingCharacters(in: .whitespaces)
        let out = editorOut.trimmingCharacters(in: .whitespaces)
        let pin = editorPriceIn.trimmingCharacters(in: .whitespaces)
        let pout = editorPriceOut.trimmingCharacters(in: .whitespaces)
        if let n = Int(ctx), n > 0 { extra["context_window"] = n } else { extra["context_window"] = NSNull() }
        if let n = Int(out), n > 0 { extra["max_output_tokens"] = n } else { extra["max_output_tokens"] = NSNull() }
        if let d = Double(pin), d >= 0 { extra["price_input"] = d } else { extra["price_input"] = NSNull() }
        if let d = Double(pout), d >= 0 { extra["price_output"] = d } else { extra["price_output"] = NSNull() }
        cloudModelAction(provider, action: "tag", model: spec.id,
                         vision: editorVision, tools: editorTools, extra: extra)
        closeCloudModelEditor()
    }

    /// F3: 连通性测试（用已存 key 探测全部 base）
    func cloudTestProvider(_ name: String) {
        actionMessage = "测试 \(name) 中…"
        var req = URLRequest(url: base.appendingPathComponent("/admin/cloud/provider-test"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": name])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var ok = false; var detail = ""
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = obj["ok"] as? Bool ?? false
                if let results = obj["results"] as? [[String: Any]] {
                    detail = results.compactMap { r in
                        let proto = r["protocol"] as? String ?? "?"
                        return r["pass"] as? Bool == true
                            ? "\(proto)✓" : "\(proto)✗ \(r["message"] as? String ?? "")"
                    }.joined(separator: " · ")
                }
                if let keySet = obj["key_set"] as? Bool, !keySet { detail += "（未设 API key）" }
            }
            DispatchQueue.main.async {
                self?.actionMessage = (200..<300).contains(code)
                    ? (ok ? "✅ \(name) 连通 \(detail)" : "❌ \(name) 不通：\(detail)")
                    : "❌ 测试失败(\(code))"
                self?.fetchCloud()
            }
        }.resume()
    }

    @Published var cloudBusy = false   // 云端操作防抖：进行中忽略重复触发（双击不再产生第二次 DELETE）

    func cloudRequest(path: String, method: String, body: [String: Any], okMsg: String, failPrefix: String, timeout: Double = 30) {
        guard !cloudBusy else {
            actionMessage = "⚠️ 上一操作进行中，请稍候"
            return
        }
        cloudBusy = true
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !body.isEmpty { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.cloudBusy = false
                self?.actionMessage = (200..<300).contains(code)
                    ? okMsg : "❌ \(failPrefix)(\(code)): \(body.prefix(100))"
                self?.fetchCloud()
                self?.fetchPools()
            }
        }.resume()
    }

    /// 能力包下载进度轮询（3s 定时器复用）
    func fetchDownloadStatus() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/admin/packs/download-status")) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONDecoder().decode([String: PackDownloadState].self, from: data) else { return }
            DispatchQueue.main.async {
                self.packDownloads = obj
                // 下载完成 → 刷新模型列表（新装包出现在能力包/本地推理）
                if obj.values.contains(where: { $0.status == "installed" }) { self.fetchModels(); self.scanLocalModels() }
            }
        }.resume()
    }

    /// 能力包一键安装：网关负责"已在盘→直接装机 / 不在→下载后装机"
    func installPack(_ name: String, url: String, filename: String, label: String, engine: String = "") {
        actionMessage = "\(name) 安装中…"
        var req = URLRequest(url: base.appendingPathComponent("/admin/packs/download"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "url": url, "filename": filename, "model_type_label": label]
        if !engine.isEmpty { body["engine"] = engine }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                if (200..<300).contains(code) {
                    self?.actionMessage = "\(name) 开始下载…进度看卡片"
                    self?.fetchDownloadStatus()
                } else {
                    self?.actionMessage = "❌ 安装失败(\(code)): \(body.prefix(120))"
                }
            }
        }.resume()
    }

    /// G4: 拉取 per-model 指标（TTFT/TPS/tokens/成本）
    func fetchMetrics() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/api/metrics")) { [weak self] data, _, _ in
            guard let self, let data,
                  let mp = try? JSONDecoder().decode(MetricsPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.metrics = mp }
        }.resume()
    }

    /// 默认启动开关 — 改 models.d YAML autostart 字段（默认 false 不自动启动）
    func setAutostart(_ name: String, _ enabled: Bool) {
        var req = URLRequest(url: base.appendingPathComponent("/admin/models/set-autostart"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "enabled": enabled])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.actionMessage = (200..<300).contains(code)
                    ? (enabled ? "✅ \(name) 将随网关启动" : "✅ \(name) 不再随网关启动")
                    : "❌ 设置失败(\(code)): \(body.prefix(100))"
                self?.fetchModels()
            }
        }.resume()
    }

    /// F4: 扫描本机模型（~/models + MacFabric/models，含根级散置 GGUF）
    func scanLocalModels() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/local-models")) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONDecoder().decode(LocalModelsPayload.self, from: data) else { return }
            DispatchQueue.main.async {
                self.localDiscovered = obj.discovered ?? []
                self.localScanned = true
            }
        }.resume()
    }

    /// F4: 安装 = 写 models.d YAML + 热重载，不启动（首请求自动唤醒）
    func installLocalModel(_ m: LocalDiscovered) {
        actionMessage = "安装 \(m.name) 中…"
        var req = URLRequest(url: base.appendingPathComponent("/admin/packs/install"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": m.name, "type": m.type ?? "llama_cpp"])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.actionMessage = (200..<300).contains(code)
                    ? "✅ \(m.name) 已安装（未启动 — 首请求自动唤醒）" : "❌ 安装失败(\(code)): \(body.prefix(120))"
                self?.fetchModels(); self?.scanLocalModels()
            }
        }.resume()
    }

    func fetchCurve() {
        URLSession.shared.dataTask(with: base.appendingPathComponent("/api/token-curve")) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let local = obj["local"] as? [[String: Any]] else { return }
            let pts = local.suffix(24).compactMap { d -> CurvePoint? in
                guard let t = d["t"] as? Double else { return nil }
                let gi: (String) -> Int = { k in (d[k] as? Int) ?? Int((d[k] as? Double) ?? 0) }
                return CurvePoint(t: t, tokens: gi("tokens"), requests: gi("requests"))
            }
            DispatchQueue.main.async { self.curve = pts }
        }.resume()
    }

    private func adminAction(_ path: String, model: String, done: @escaping (String) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                done((200..<300).contains(code) ? "✅ \(model) 完成"
                     : "❌ \(model) 失败(\(code)): \(body.prefix(120))")
                self?.refresh(); self?.fetchModels()
            }
        }.resume()
    }

    func switchModel(_ name: String, force: Bool = false) {
        actionMessage = force ? "已确认超卖，加载 \(name) 中…" : "切换 \(name) 中…（首次加载约 5~10s）"
        var req = URLRequest(url: base.appendingPathComponent("/switch"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "force": force])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if code == 409, let obj = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                   obj["status"] as? String == "memory_insufficient" {
                    self.actionMessage = ""
                    self.onMemoryInsufficient?(name, obj["message"] as? String ?? "内存不足")
                    return
                }
                self.actionMessage = (200..<300).contains(code)
                    ? "✅ \(name) 完成" : "❌ \(name) 失败(\(code)): \(body.prefix(120))"
                self.refresh(); self.fetchModels()
            }
        }.resume()
    }
    func stopService(_ name: String) {
        actionMessage = "停止 \(name) 中…"
        adminAction("/stop", model: name) { [weak self] msg in self?.actionMessage = msg }
    }
    func sleepModel(_ name: String) {
        actionMessage = "\(name) 睡眠中…（唤醒约 2s）"
        adminAction("/sleep", model: name) { [weak self] msg in self?.actionMessage = msg }
    }
    func wakeModel(_ name: String) {
        actionMessage = "唤醒 \(name) 中…"
        adminAction("/wake", model: name) { [weak self] msg in self?.actionMessage = msg }
    }

    func sendPrompt() {
        busy = true; reply = ""
        // 试聊模型动态解析：首个活跃 LLM → 兜底 qwen3-4b（轻量对话包卸载后不哑）
        let target = models.first { $0.active == true && $0.model_type == "llm" }?.name
            ?? (models.contains { $0.name == "qwen3-4b" } ? "qwen3-4b" : (models.first?.name ?? "qwen3-4b"))
        var req = URLRequest(url: base.appendingPathComponent("/v1/chat/completions"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": target, "max_tokens": 300,
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": prompt]],
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            defer { DispatchQueue.main.async { self?.busy = false } }
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    self?.reply = "请求失败(\(code)) \(detail.prefix(140)) — 若模型未装，先到能力包页安装轻量对话包"
                }
                return
            }
            let content = (msg["content"] as? String) ?? ""
            DispatchQueue.main.async {
                // 思考模型可能吃满 max_tokens 致 content 为空 — 如实提示而非报错
                self.reply = content.isEmpty ? "（模型思考占满了输出预算，未产出正文 — 重试或换个模型）" : content
            }
        }.resume()
    }

    // 织物条数据：预算 B、已用、系统保留 8G
    var budgetMB: Int { snapshot?.status.gpu_total_mb ?? 0 }
    var usedMB: Int { snapshot?.status.gpu_used_mb ?? 0 }
    var reserveMB: Int { 8192 }
    var freeRatio: Double {
        guard budgetMB > 0 else { return 0 }
        return max(Double(budgetMB - usedMB - reserveMB) / Double(budgetMB), 0)
    }
    var totalRequests: Int { curve.reduce(0) { $0 + $1.requests } }
    var totalTokens: Int { curve.reduce(0) { $0 + $1.tokens } }
}

// ─── 通用元件（照设计稿 .card/.pill/.stat/.ccard）───────────────

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(Color.glass)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.lineC, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct Pill: View {
    enum Kind { case run, sleep, stop, err }
    let kind: Kind
    static func from(active: Bool?, health: String?, sleeping: Bool = false) -> Kind {
        if health == "❌" { return .err }
        if sleeping { return .sleep }
        return active == true ? .run : .stop
    }
    static func make(active: Bool?, health: String?, sleeping: Bool = false) -> Pill {
        Pill(kind: from(active: active, health: health, sleeping: sleeping))
    }
    var label: String {
        switch kind { case .run: "运行中"; case .sleep: "睡眠"; case .stop: "已停止"; case .err: "异常" }
    }
    var color: Color {
        switch kind { case .run: .okC; case .sleep: .warnC; case .stop: .faint; case .err: .red }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 2.5)
        .background(color.opacity(0.13), in: Capsule())
        .foregroundStyle(color)
    }
}

struct WeaveSeg {
    let color: Color
    let ratio: Double
    let name: String
    let gb: String
}

/// 内存织物条（心脏组件）：能力线段 + 空闲 + 系统保留
struct WeaveBar: View {
    var segments: [WeaveSeg]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle()
                        .fill(s.color)
                        .frame(width: max(geo.size.width * s.ratio, 3))
                }
            }
        }
        .frame(height: 34)
        .background(Color.black.opacity(0.03))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.lineC, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

// ─── 侧栏（.sbar：平台 / 获取 / 设置 三组）──────────────────────

struct Sidebar: View {
    var tab: Binding<Int>
    private let platform = [(0, "总览"), (1, "模型服务"), (2, "本地推理"), (3, "模型池"), (4, "监控台")]
    private let acquire = [(5, "能力包"), (6, "云端接入")]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("平台").font(.system(size: 11)).foregroundColor(.faint)
                .padding(10).padding(.top, 6)
            ForEach(platform, id: \.1) { item in
                SideItem(label: item.1, on: tab.wrappedValue == item.0) { tab.wrappedValue = item.0 }
            }
            Text("获取").font(.system(size: 11)).foregroundColor(.faint)
                .padding(10).padding(.top, 14)
            ForEach(acquire, id: \.1) { item in
                SideItem(label: item.1, on: tab.wrappedValue == item.0) { tab.wrappedValue = item.0 }
            }
            Spacer()
            SideItem(label: "设置", on: tab.wrappedValue == 7) { tab.wrappedValue = 7 }
                .padding(.bottom, 10)
        }
        .frame(width: 172)
        .padding(.horizontal, 8)
        .background(Color.black.opacity(0.025))
    }
}

struct SideItem: View {
    let label: String
    let on: Bool
    var placeholder = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? Color.accent : Color.faint)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.system(size: 13.5))
                    .foregroundColor(placeholder ? .faint : (on ? .ink : .dim))
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(on ? Color.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(placeholder)
    }
}

// ─── 总览页（织物条 + 统计瓦片 + 能力卡格）──────────────────────

struct OverviewView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(store.gatewayUp ? Color.okC : Color.red).frame(width: 9, height: 9)
                    Text(store.gatewayUp ? "网关运行中 :\(GW_PORT)" : "网关未响应")
                        .font(.system(size: 12.5)).foregroundColor(.dim)
                    Spacer()
                    Text(store.snapshot?.status.gpu_mode ?? "idle")
                        .font(.system(size: 11.5)).foregroundColor(.faint)
                }
                // 织物条
                WeaveBar(segments: weaveSegments)
                HStack(spacing: 14) {
                    ForEach(weaveSegments, id: \.name) { s in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(s.color)
                                .frame(width: 9, height: 9)
                            Text("\(s.name) \(s.gb)").font(.system(size: 11.5)).foregroundColor(.dim)
                        }
                    }
                }
                Text("**\(String(format: "%.1f", Double(store.usedMB) / 1024))** / \(String(format: "%.0f", Double(store.budgetMB) / 1024)) GB · 预算 B = RAM − 8G")
                    .font(.system(size: 12.5)).foregroundColor(.dim)
                // 统计瓦片
                HStack(spacing: 12) {
                    StatCard(v: "\(store.models.filter { $0.active == true }.count)",
                             k: "运行中 · \(store.models.count) 个模型")
                    StatCard(v: "\(store.totalRequests)", k: "24h 请求")
                    StatCard(v: formatCount(store.totalTokens), k: "24h 本地 tokens")
                    StatCard(v: store.gatewayUp ? "在线" : "离线", k: "网关 :\(GW_PORT)")
                }
                // 能力卡格
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
                    ForEach(store.models, id: \.name) { m in
                        CapabilityCard(model: m,
                                       sleeping: store.snapshot?.status.sleep_states?[m.name] != nil)
                    }
                }
            }
            .padding(18)
        }
    }

    private var weaveSegments: [WeaveSeg] {
        var segs: [WeaveSeg] = []
        let active = store.models.filter { $0.active == true }
        for m in active {
            let mb = m.peak_vram_mb ?? 3100
            let ratio = store.budgetMB > 0 ? Double(mb) / Double(store.budgetMB) : 0
            segs.append(WeaveSeg(color: threadColor(m.model_type), ratio: ratio, name: m.name,
                         gb: String(format: "%.1f", Double(mb) / 1024)))
        }
        segs.append(WeaveSeg(color: Color.black.opacity(0.06), ratio: store.freeRatio, name: "空闲",
                     gb: String(format: "%.1f", Double(max(store.budgetMB - store.usedMB - store.reserveMB, 0)) / 1024)))
        segs.append(WeaveSeg(color: Color.black.opacity(0.10), ratio: Double(store.reserveMB) / Double(max(store.budgetMB, 1)), name: "系统保留", gb: "8.0"))
        return segs
    }

    private func formatCount(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1_000 ? String(format: "%.1fK", Double(n) / 1_000) : "\(n)"
    }
}

struct StatCard: View {
    let v: String
    let k: String
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                Text(v).font(.system(size: 19, weight: .bold, design: .monospaced))
                Text(k).font(.system(size: 11.5)).foregroundColor(.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

struct CapabilityCard: View {
    let model: ModelItem
    var sleeping = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(threadColor(model.model_type))
                        .frame(width: 10, height: 10)
                    Text(humanName(model.model_type))
                        .font(.system(size: 13.5, weight: .semibold)).foregroundColor(.ink)
                }
                Text(model.name).font(.system(size: 12)).foregroundColor(.dim).lineLimit(1)
                HStack {
                    Pill.make(active: model.active, health: nil, sleeping: sleeping)
                    Spacer()
                    Text(sleeping ? "唤醒约 2s"
                         : model.peak_vram_mb.map { String(format: "%.1f GB", Double($0) / 1024) } ?? "按需")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundColor(.faint)
                }
            }
            .padding(13)
        }
    }
}

// ─── 模型服务页（Hub：接入地址条 + 每模型接入卡）────────────────

struct HubView: View {
    @ObservedObject var store: GatewayStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    HStack(spacing: 10) {
                        Chip("接入地址")
                        Text(GW_BASE).font(.system(size: 12, design: .monospaced)).foregroundColor(.ink)
                        Chip("鉴权未启用")
                        Spacer()
                        CopyButton("复制 Base URL", text: GW_BASE, small: true)
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }
                ForEach(store.models, id: \.name) { m in
                    HubRow(model: m,
                           sleeping: store.snapshot?.status.sleep_states?[m.name] != nil,
                           expanded: Binding(get: { store.hubExpanded == m.name },
                                             set: { store.hubExpanded = $0 ? m.name : "" }))
                }
            }.padding(16)
        }
    }
}

struct HubRow: View {
    let model: ModelItem
    var sleeping: Bool
    @Binding var expanded: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.faint)
                        RoundedRectangle(cornerRadius: 3).fill(threadColor(model.model_type))
                            .frame(width: 9, height: 9)
                        Text(model.name).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                        Chip("本机 · \(humanName(model.model_type))")
                        if sleeping { Pill(kind: .sleep) } else { Pill.make(active: model.active, health: nil) }
                        Spacer()
                        CopyButton("复制配置", text: configJSON, small: true)
                        CopyButton("cURL", text: curlFor, small: true)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 7)

                if expanded {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldRow(k: "OpenAI", v: "\(GW_BASE)/v1 · 模型 ID: \(model.name)")
                        FieldRow(k: "Anthropic", v: "\(GW_BASE) · ANTHROPIC_MODEL=\(model.name)")
                        CopyButton("复制环境变量", text: "export ANTHROPIC_BASE_URL=\(GW_BASE)\nexport ANTHROPIC_MODEL=\(model.name)", small: true)
                        Text("已停止的按需模型照样能调 — 首请求自动唤醒，约 2s")
                            .font(.system(size: 10.5)).foregroundColor(.faint)
                    }
                    .padding(.leading, 12).padding(.bottom, 10).padding(.trailing, 12)
                }
            }
        }
    }
    var configJSON: String {
        "{\"base_url\": \"\(GW_BASE)/v1\", \"model\": \"\(model.name)\", \"api_key\": \"未启用鉴权\"}"
    }
    var curlFor: String {
        "curl \(GW_BASE)/v1/chat/completions -H \"Content-Type: application/json\" -d '{\"model\":\"\(model.name)\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
    }
}

struct Chip: View {
    let text: String
    var color: Color? = nil            // 线色参数：VL 徽章等能力染色
    init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.system(size: 11.5))
            .foregroundColor(color ?? .dim)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .overlay(Capsule().stroke(color ?? Color.lineC, lineWidth: 1))
            .background(color.map { $0.opacity(0.10) } ?? Color.black.opacity(0.045), in: Capsule())
    }
}

struct FieldRow: View {
    let k: String
    let v: String
    var body: some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 11.5)).foregroundColor(.faint).frame(width: 64, alignment: .leading)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundColor(.dim).lineLimit(1)
            Spacer()
            CopyButton("复制", text: v, small: true)
        }
    }
}

struct CopyButton: View {
    let title: String
    let text: String
    var small = false
    init(_ title: String, text: String, small: Bool = false) {
        self.title = title; self.text = text; self.small = small
    }
    var body: some View {
        Button(title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .font(.system(size: small ? 10.5 : 11.5))
        .buttonStyle(.plain)
        .padding(.horizontal, small ? 7 : 10).padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.lineC, lineWidth: 1))
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .foregroundColor(.ink)
    }
}

// ─── 本地推理页（.mrow 一行一模型 + 底部试聊）────────────────────

struct InferenceView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.models, id: \.name) { m in
                        ModelRowView(store: store, m: m,
                                     sleeping: store.snapshot?.status.sleep_states?[m.name] != nil)
                    }
                }.padding(16)
            }
            Divider().overlay(Color.lineC)
            ChatStrip(store: store)
        }
    }
}

/// 设计稿 .mrow：一行一模型 — 状态、装载模式、内存账、三个动作
struct ModelRowView: View {
    @ObservedObject var store: GatewayStore
    let m: ModelItem
    var sleeping: Bool

    var body: some View {
        Card {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(threadColor(m.model_type))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                    Text("\(engineLabel) · :\(portText)")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.faint)
                }
                if sleeping { Pill(kind: .sleep) } else { Pill.make(active: m.active, health: nil) }
                // F5: VL 能力徽章（model_type == vl）
                if m.model_type == "vl" { Chip("VL", color: Color.thVl) }
                Chip(loadChip)                       // 装载模式 chip
                // 默认启动开关（用户裁决：默认 false 不自动启动）
                HStack(spacing: 4) {
                    Text("默认启动").font(.system(size: 10.5)).foregroundColor(.faint)
                    Toggle("", isOn: Binding(
                        get: { m.autostart ?? false },
                        set: { store.setAutostart(m.name, $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .help("开启后网关启动时自动拉起该模型；默认关闭 — 首个请求才唤醒")
                }
                Text("基线 \(baselineGB)")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.dim)
                Spacer()
                HStack(spacing: 6) {
                    if sleeping {
                        SmallBtn("唤醒", primary: true) { store.wakeModel(m.name) }
                    } else if m.active == true {
                        SmallBtn("睡眠") { store.sleepModel(m.name) }
                        SmallBtn("停止") { store.stopService(m.name) }
                    } else {
                        SmallBtn("启动", primary: true) { store.switchModel(m.name) }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    var engineLabel: String {
        m.type == "llama_cpp" ? "llama.cpp" : (m.type ?? "")
    }
    var portText: String {
        store.snapshot?.status.services_info?[m.name]?.port.map(String.init) ?? "—"
    }
    var loadChip: String {
        (m.ledgerMode == "resident") ? "常驻" : "按需 · 空闲30min卸载"
    }
    var baselineGB: String {
        let mb = m.peak_vram_mb ?? 0
        return mb > 0 ? String(format: "%.1f GB", Double(mb) / 1024) : "—"
    }
}

struct SmallBtn: View {
    var title: String
    var primary = false
    var disabled = false
    let action: () -> Void
    init(_ title: String, primary: Bool = false, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.primary = primary; self.disabled = disabled; self.action = action
    }
    var body: some View {
        Button(title, action: action)
            .font(.system(size: 11.5, weight: primary ? .semibold : .regular))
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(primary ? Color.accent : Color.black.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(primary ? Color.accent : Color.lineC, lineWidth: 1))
            .foregroundColor(primary ? .white : .ink)
    }
}

struct ChatStrip: View {
    @ObservedObject var store: GatewayStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("试聊 · 经 :\(GW_PORT) 网关").font(.system(size: 11.5)).foregroundColor(.faint)
            HStack(spacing: 8) {
                TextField("输入…", text: Binding(get: { store.prompt }, set: { store.prompt = $0 }))
                    .textFieldStyle(.roundedBorder)
                SmallBtn(store.busy ? "推理中…" : "发送", primary: !store.busy) { store.sendPrompt() }
                    .disabled(store.busy)
            }
            if !store.reply.isEmpty {
                ScrollView {
                    Text(store.reply).font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 110)
            }
        }
        .padding(12)
    }
}

// ─── 模型池 / 监控台 ────────────────────────────────────────────

/// 模型池：真数据（GET /admin/model-pools）— 角色池 + 竖排候选链 + 优先级可调（CAS PUT）
let poolUseLabels: [String: String] = [
    "fast": "快速对话 · 低延迟优先",
    "small": "轻量任务 · 意图分类",
    "premium": "高质量长文 · 云端兜底",
]

struct PoolsView: View {
    @ObservedObject var store: GatewayStore

    static let usageSnippet = """
    curl http://127.0.0.1:\(GW_PORT)/v1/chat/completions \\
      -H "Authorization: Bearer sk-iff-…" -H "Content-Type: application/json" \\
      -d '{"model":"iff/fast","messages":[{"role":"user","content":"你好"}]}'
    """

    static func copyUsageSnippet() {
        let text = """
        # MacFabric 池调用（OpenAI 方言；Anthropic 方言把 URL 换成 http://127.0.0.1:\(GW_PORT) 即可）
        export OPENAI_BASE_URL=http://127.0.0.1:\(GW_PORT)/v1
        export OPENAI_API_KEY=sk-iff-…   # 设置页「API Key 鉴权」新建
        # model 填池名：iff/fast · iff/small · iff/premium（按池内优先级自动调度）
        \(usageSnippet)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder private func guideRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.ink)
            Text(detail).font(.system(size: 11)).foregroundColor(.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !store.actionMessage.isEmpty {
                    Text(store.actionMessage).font(.system(size: 12))
                        .padding(8).frame(maxWidth: .infinity)
                        .background(Color.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if let pools = store.pools, let cfg = pools.pools, !cfg.isEmpty {
                    // 固定角色序：fast → small → premium，其余追加
                    let order = ["fast", "small", "premium"]
                    let names = cfg.keys.sorted { (a, b) in
                        let ia = order.firstIndex(of: a) ?? 99
                        let ib = order.firstIndex(of: b) ?? 99
                        return ia != ib ? ia < ib : a < b
                    }
                    ForEach(names, id: \.self) { name in
                        PoolCard(store: store, name: name, def: cfg[name]!)
                    }
                    // 调用指引（用户视角 — 客户端怎么用这些池）
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("如何调用这些池").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                                Spacer()
                                SmallBtn("复制调用示例") { Self.copyUsageSnippet() }
                            }
                            guideRow("① 服务地址（Base URL）",
                                     "OpenAI 方言 \(GW_BASE)/v1 · Anthropic 方言 \(GW_BASE)")
                            guideRow("② 模型名（model）",
                                     "直接填池名：iff/fast · iff/small · iff/premium — 网关按池内优先级自动选候选，失败自动换下一个，无需改客户端")
                            guideRow("③ API Key",
                                     store.securityEnforced
                                        ? "鉴权已开启 — 用设置页「API Key 鉴权 → ＋ 新建密钥」生成的 sk-iff-…，请求头 Authorization: Bearer <key>"
                                        : "鉴权未开启 — 本机调用免 key；开启鉴权后在设置页新建")
                            Text("示例（终端可直接粘贴）")
                                .font(.system(size: 10.5)).foregroundColor(.dim)
                            Text(Self.usageSnippet)
                                .font(.system(size: 10.5, design: .monospaced)).foregroundColor(.dim)
                                .lineLimit(4).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }.padding(12)
                    }
                } else {
                    Card {
                        Text(store.gatewayUp ? "池配置加载中…" : "网关离线 — 启动后此处显示角色池")
                            .font(.system(size: 12)).foregroundColor(.faint)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }.padding(16)
        }
    }
}

struct PoolCard: View {
    @ObservedObject var store: GatewayStore
    let name: String
    let def: PoolDef

    var candidates: [PoolCandidate] {
        (def.candidates ?? []).sorted { $0.priority < $1.priority }
    }
    var use: String { poolUseLabels[name] ?? "" }
    var activeCount: Int { candidates.filter { isActive($0) }.count }

    func isActive(_ c: PoolCandidate) -> Bool {
        if c.kind == "cloud" {
            // 云端候选：注册表在位即可路由（云端无"启动中"状态，灰点会被
            // 误读为不可用）— 按 provider/model_id 精确比对
            guard let target = c.target, let slash = target.firstIndex(of: "/") else { return false }
            let provider = String(target[target.startIndex..<slash])
            let mid = String(target[target.index(after: slash)...])
            return (store.cloud?.models ?? []).contains { $0.provider == provider && $0.id == mid }
        }
        return localModel(c)?.active == true
    }
    func localModel(_ c: PoolCandidate) -> ModelItem? {
        store.models.first { $0.name == (c.target ?? c.id) }
    }
    func isVL(_ c: PoolCandidate) -> Bool {
        if c.kind != "cloud" { return localModel(c)?.model_type == "vl" }
        // 云端候选：按注册表 supports_vision 三态
        guard let specs = store.cloud?.providers?.first(where: { c.target?.hasPrefix("\($0.name)/") == true })?.model_specs else { return false }
        return specs.first(where: { c.target?.hasSuffix("/\($0.id)") == true })?.supports_vision == true
    }

    /// 云端候选是否支持 anthropic 协议（注册表 anthropic_available 三态；
    /// target 形如 "atlaswork/kimi/k3.1-pro"，按首个 "/" 拆 provider/model_id）
    func cloudAnthropic(_ c: PoolCandidate) -> Bool {
        guard let target = c.target, let slash = target.firstIndex(of: "/") else { return false }
        let provider = String(target[target.startIndex..<slash])
        let mid = String(target[target.index(after: slash)...])
        let list = store.cloud?.models ?? []
        let hit = list.first(where: { m in m.provider == provider && m.id == mid })
        return hit?.anthropic_available == true
    }

    /// 可作候选的云端模型（provider/model 形式）— spec 行 ∪ 已启用未建 spec
    /// 的发现模型（enable 只进白名单，不建 model_specs；漏掉会让已启用模型
    /// 在池页添加菜单隐身）
    var cloudChoices: [(String, String)] {
        var out: [(String, String)] = []
        for pv in store.cloud?.providers ?? [] {
            var seen = Set<String>()
            for spec in pv.model_specs ?? [] {
                out.append(("\(pv.name)/\(spec.id)", pv.name))
                seen.insert(spec.id)
            }
            for mid in pv.enabled_models ?? [] where !seen.contains(mid) {
                out.append(("\(pv.name)/\(mid)", pv.name))
            }
        }
        return out
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("iff/\(name)").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                    Text(use).font(.system(size: 11.5)).foregroundColor(.dim)
                    Spacer()
                    Text(activeCount > 0 ? "● 调用中" : "\(candidates.count) 候选")
                        .font(.system(size: 11)).foregroundColor(activeCount > 0 ? .okC : .faint)
                    // F8: 池级启停（服务端字段级 CAS）
                    SmallBtn((def.enabled ?? true) ? "已启用" : "已停用",
                             primary: def.enabled ?? true) {
                        store.togglePool(name, enabled: !(def.enabled ?? true))
                    }
                }
                ForEach(Array(candidates.enumerated()), id: \.element.rowKey) { idx, c in
                    HStack(spacing: 8) {
                        Text("\(c.priority)").font(.system(size: 11, design: .monospaced)).foregroundColor(.faint)
                            .frame(width: 16)
                        Circle().fill(isActive(c) ? Color.okC : Color.faint.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(c.target ?? c.id).font(.system(size: 12.5)).foregroundColor(.ink)
                        Chip(c.kind == "cloud" ? "云端" : "本机")
                        // F5: VL 能力徽章（本地模型 model_type == vl）
                        if isVL(c) {
                            Chip("VL", color: Color.thVl)
                        }
                        if idx == 0 {
                            Text("首选").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                                .foregroundColor(.accent)
                        }
                        // 协议标签：本地 openai 恒有 + anthropic 协议；云端按注册表三态
                        if c.kind != "cloud" {
                            Chip("openai")
                            if localModel(c)?.anthropic_native == true { Chip("anthropic", color: Color.thJudge) }
                        } else {
                            Chip("openai", color: Color.thLlm)
                            if cloudAnthropic(c) { Chip("anthropic", color: Color.thJudge) }
                        }
                        Spacer()
                        // 换模型：本机 + 云端全部模型可作候选
                        Menu("换") {
                            Section("本机") {
                                ForEach(store.models, id: \.name) { m in
                                    Button(m.name) {
                                        store.confirm("将候选 \(c.target ?? c.id) 替换为 \(m.name)？") {
                                            store.replacePoolCandidate(pool: name, candidateId: c.id,
                                                                       to: m.name, kind: "local")
                                        }
                                    }
                                }
                            }
                            Section("云端") {
                                ForEach(cloudChoices, id: \.0) { ch in
                                    Button(ch.0) {
                                        store.confirm("将候选 \(c.target ?? c.id) 替换为 \(ch.0)？") {
                                            store.replacePoolCandidate(pool: name, candidateId: c.id,
                                                                       to: ch.0, kind: "cloud")
                                        }
                                    }
                                }
                            }
                        }
                        .font(.system(size: 11))
                        SmallBtn("移除") {
                            store.confirm("从池 iff/\(name) 移除候选 \(c.target ?? c.id)？") {
                                store.removePoolCandidate(pool: name, candidateId: c.id)
                            }
                        }
                        // F1: 优先级可调 — ↑↓/拖拽移动位置，priority 全量重建（CAS 回写）
                        HStack(spacing: 3) {
                            SmallBtn("↑", disabled: idx == 0) {
                                store.reorderCandidate(pool: name, candidateId: c.id, up: true)
                            }
                            SmallBtn("↓", disabled: idx == candidates.count - 1) {
                                store.reorderCandidate(pool: name, candidateId: c.id, up: false)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .opacity(store.poolDragging == c.id ? 0.4 : 1)
                    .onDrag {
                        store.poolDragging = c.id
                        return NSItemProvider(object: c.id as NSString)
                    }
                    .onDrop(of: ["public.utf8-plain-text"],
                            delegate: PoolRowDropDelegate(store: store, pool: name, targetId: c.id))
                }
                if candidates.isEmpty {
                    Text("暂无候选 — 点下方「＋ 添加候选」选本机或云端模型")
                        .font(.system(size: 11)).foregroundColor(.faint).padding(.vertical, 4)
                }
                // 追加候选
                HStack(spacing: 8) {
                    Menu("＋ 添加候选") {
                        Section("本机") {
                            ForEach(store.models, id: \.name) { m in
                                Button(m.name) { store.addPoolCandidate(pool: name, target: m.name, kind: "local") }
                            }
                        }
                        Section("云端") {
                            ForEach(cloudChoices, id: \.0) { ch in
                                Button(ch.0) { store.addPoolCandidate(pool: name, target: ch.0, kind: "cloud") }
                            }
                        }
                    }
                    .font(.system(size: 11))
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(12)
        }
    }
}

// 池候选行拖拽落点 — 命中即把拖拽候选移到本行位置（priority 全量重建，CAS 回写）
struct PoolRowDropDelegate: DropDelegate {
    var store: GatewayStore
    let pool: String
    let targetId: String

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragging = store.poolDragging else { return false }
        return dragging != targetId
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = store.poolDragging else { return false }
        store.poolDragging = nil
        guard dragged != targetId else { return true }
        store.moveCandidate(pool: pool, dragged: dragged, target: targetId)
        return true
    }
}

struct MonitorView: View {
    @ObservedObject var store: GatewayStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatCard(v: "\(store.totalRequests)", k: "24h 请求")
                    StatCard(v: "\(store.totalTokens)", k: "24h tokens")
                    StatCard(v: store.gatewayUp ? "在线" : "离线", k: "网关状态")
                    if let m = store.metrics {
                        let ok = m.success ?? 0, all = (m.success ?? 0) + (m.fail ?? 0)
                        StatCard(v: all > 0 ? "\(Int(Double(ok) / Double(all) * 100))%" : "—", k: "成功率")
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每小时请求数（近 24h）").font(.system(size: 12.5)).foregroundColor(.dim)
                        if store.curve.isEmpty {
                            Text("暂无数据 — 发起一次对话后这里会出现柱状图")
                                .foregroundColor(.faint).frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            Chart(store.curve, id: \.t) { p in
                                BarMark(
                                    x: .value("时间", Date(timeIntervalSince1970: p.t)),
                                    y: .value("请求", p.requests)
                                )
                                .foregroundStyle(Color.accent.opacity(0.75))
                            }
                            .chartYAxis(.hidden)
                            .frame(height: 140)
                        }
                    }.padding(14)
                }
                // G4: per-model 指标表（TTFT/TPS/tokens/成本）
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型指标（24h）").font(.system(size: 12.5)).foregroundColor(.dim)
                        // 列宽合计 610pt+ — 窄窗口横向滚动，不裁切
                        ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            metricHead("模型").frame(width: 130, alignment: .leading)
                            metricHead("来源").frame(width: 50)
                            metricHead("请求").frame(width: 50)
                            metricHead("tokens").frame(width: 90)
                            metricHead("TTFT p50").frame(width: 80)
                            metricHead("TTFT p95").frame(width: 80)
                            metricHead("TPS").frame(width: 60)
                            metricHead("成本").frame(width: 70)
                            Spacer()
                        }
                        ForEach(metricRows, id: \.name) { r in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Circle().fill(r.color).frame(width: 7, height: 7)
                                    Text(r.name).font(.system(size: 12)).foregroundColor(.ink).lineLimit(1)
                                }.frame(width: 130, alignment: .leading)
                                Text(r.source).font(.system(size: 11)).foregroundColor(.dim).frame(width: 50)
                                Text("\(r.requests)").font(.system(size: 11.5, design: .monospaced)).foregroundColor(.ink).frame(width: 50)
                                Text("\(r.tokensIn)/\(r.tokensOut)").font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 90)
                                Text(r.ttft50).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 80)
                                Text(r.ttft95).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 80)
                                Text(r.tps).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 60)
                                Text(r.cost).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 70)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            Rectangle().fill(Color.lineC).frame(height: 1)
                        }
                        if metricRows.isEmpty {
                            Text("暂无调用数据").font(.system(size: 11.5)).foregroundColor(.faint)
                        }
                        }
                    }.padding(14)
                }
            }.padding(18)
        }
    }

    struct MetricRow {
        let name: String; let color: Color; let source: String
        let requests: Int; let tokensIn: Int; let tokensOut: Int
        let ttft50: String; let ttft95: String; let tps: String; let cost: String
    }

    var metricRows: [MetricRow] {
        guard let models = store.metrics?.models else { return [] }
        return models.keys.sorted().compactMap { name in
            guard let mm = models[name] else { return nil }
            let isCloud = mm.source == "cloud"
            let hasTraffic = (mm.requests ?? 0) > 0
            return MetricRow(
                name: name,
                color: isCloud ? Color.thLlm : (hasTraffic ? Color.okC : Color.faint.opacity(0.6)),
                source: isCloud ? "云端" : "本机",
                requests: mm.requests ?? 0,
                tokensIn: mm.tokens_in ?? 0, tokensOut: mm.tokens_out ?? 0,
                ttft50: mm.ttft_p50.map { String(format: "%.0fms", $0) } ?? "—",
                ttft95: mm.ttft_p95.map { String(format: "%.0fms", $0) } ?? "—",
                tps: mm.e2e_tps_p50.map { String(format: "%.1f", $0) } ?? "—",
                cost: String(format: "¥%.2f", mm.cost_yuan ?? 0))
        }
    }

    func metricHead(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5)).foregroundColor(.faint)
    }
}

// ─── 主窗口：侧栏 + 内容区 ─────────────────────────────────────

struct MainWindowView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(tab: Binding(get: { store.tab }, set: { store.tab = $0 }))
            Rectangle().fill(Color.lineC).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.panel)
        }
        .background(Color.panel)
        .preferredColorScheme(.light)
        .confirmationDialog(store.confirmText ?? "",
                            isPresented: Binding(get: { store.confirmText != nil },
                                                 set: { if !$0 { store.confirmText = nil; store.confirmAction = nil } }),
                            titleVisibility: .visible) {
            Button("确认", role: .destructive) {
                store.confirmAction?()
                store.confirmText = nil; store.confirmAction = nil
            }
            Button("取消", role: .cancel) {
                store.confirmText = nil; store.confirmAction = nil
            }
        } message: {
            Text(store.confirmText ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        switch store.tab {
        case 0: OverviewView(store: store)
        case 1: HubView(store: store)
        case 2: InferenceView(store: store)
        case 3: PoolsView(store: store)
        case 4: MonitorView(store: store)
        case 5: PacksView(store: store)
        case 6: CloudView(store: store)
        case 7: SettingsView(store: store)
        default: OverviewView(store: store)
        }
    }
}

/// 能力包：产品主入口 —— 装的是能力不是模型文件（v1 静态目录 + 安装态对齐 models.d）
struct PacksView: View {
    @ObservedObject var store: GatewayStore

    // (线色 model_type, 能力名, 描述, 大小GB nil=内置, 对应模型名)
    let packs: [(String, String, String, String?, String?)] = [
        ("llm", "轻量对话", "qwen3-4b · 中文对话与工具调用 · 按需", "3.1", "qwen3-4b"),
        ("embedding", "通用文本嵌入", "bge-m3 · 中英多语 · 常驻", "1.2", "bge-m3"),
        ("judge", "决策判官", "qwen3-1.7b · 意图分类与路由 · 常驻", "1.4", "qwen3-1.7b"),
        ("rerank", "检索重排", "bge-reranker-v2-m3 · 常驻", "1.2", "bge-reranker-v2-m3"),
        ("tts", "中文语音合成", "kokoro-82m · 含系统语音兜底 · 常驻", "0.6", "kokoro-82m"),
        ("asr", "语音转写", "whisper-v3-turbo · 中英 · 按需", "1.6", "whisper-v3-turbo"),
        ("vl", "轻量看图", "qwen3-vl-4b · 截图理解 · 按需", "3.8", "qwen3-vl-4b"),
        ("ocr", "屏幕与文档识别", "macOS 视觉框架 · 零模型 · 常驻", nil, nil),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !store.actionMessage.isEmpty {
                    Text(store.actionMessage).font(.system(size: 12))
                        .padding(8).frame(maxWidth: .infinity)
                        .background(Color.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(packs, id: \.1) { pk in
                        PackCard(store: store, pack: pk)
                    }
                }
                // F4: 本机模型发现/安装（与卸载对称；安装不启动）
                LocalDiscoverCard(store: store)
            }
            .padding(16)
        }
    }
}

/// F4: 本机模型发现 — 扫描 ~/models 与 MacFabric/models（含根级散置 GGUF）
struct LocalDiscoverCard: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("本机模型发现").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                    Text("~/models · MacFabric/models").font(.system(size: 11)).foregroundColor(.faint)
                    Spacer()
                    SmallBtn("扫描") { store.scanLocalModels() }
                }
                if !store.localScanned {
                    Text("点「扫描」查找未配置的本地模型（GGUF / vLLM 目录 / Ollama）")
                        .font(.system(size: 11.5)).foregroundColor(.faint)
                } else if store.localDiscovered.isEmpty {
                    Text("没有新发现 — 磁盘上的模型都已配置").font(.system(size: 11.5)).foregroundColor(.faint)
                } else {
                    ForEach(store.localDiscovered, id: \.name) { m in
                        HStack(spacing: 8) {
                            Circle().fill(threadColor(m.type)).frame(width: 8, height: 8)
                            Text(m.name).font(.system(size: 12.5)).foregroundColor(.ink)
                            if let mb = m.size_mb, mb > 0 {
                                Text("\(mb) MB").font(.system(size: 11, design: .monospaced)).foregroundColor(.faint)
                            }
                            Chip(m.framework ?? m.type ?? "模型")
                            Spacer()
                            SmallBtn("安装", primary: true) { store.installLocalModel(m) }
                                .help("写入 models.d 并热重载；不会启动 — 首请求自动唤醒")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(12)
        }
    }
}

struct PackCard: View {
    @ObservedObject var store: GatewayStore
    let pack: (String, String, String, String?, String?)

    // (下载URL, 文件名, model_type 线色标签, engine?) — engine 非空 = 先项目内建引擎再下模型
    static let packPresets: [String: (String, String, String, String?)] = [
        "bge-m3": ("https://hf-mirror.com/gpustack/bge-m3-GGUF/resolve/main/bge-m3-Q4_K_M.gguf",
                   "bge-m3-Q4_K_M.gguf", "embedding", nil),
        "bge-reranker-v2-m3": ("https://hf-mirror.com/gpustack/bge-reranker-v2-m3-GGUF/resolve/main/bge-reranker-v2-m3-Q4_K_M.gguf",
                               "bge-reranker-v2-m3-Q4_K_M.gguf", "rerank", nil),
        "qwen3-1.7b": ("https://hf-mirror.com/lmstudio-community/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf",
                       "Qwen3-1.7B-Q4_K_M.gguf", "llm", nil),
        "qwen3-vl-4b": ("https://hf-mirror.com/lmstudio-community/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3-VL-4B-Instruct-Q4_K_M.gguf",
                        "Qwen3-VL-4B-Instruct-Q4_K_M.gguf", "vl", nil),
        "whisper-v3-turbo": ("https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
                             "ggml-large-v3-turbo.bin", "asr", "whisper"),
    ]
    var confirmingUninstall: Bool { store.uninstallConfirm == pack.1 }   // 两击确认，防误删

    var installed: Bool {
        guard let target = pack.4 else { return true }          // OCR 内置即就绪
        return store.models.contains { $0.name == target }
    }
    var modelType: String? {
        guard let target = pack.4 else { return "ocr" }
        return store.models.first { $0.name == target }?.model_type ?? pack.0
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(threadColor(modelType))
                        .frame(width: 10, height: 10)
                    Text(pack.1).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                }
                Text(pack.2).font(.system(size: 11.5)).foregroundColor(.dim).lineLimit(2)
                HStack {
                    Text(pack.3 ?? "内置").font(.system(size: 11.5, design: .monospaced)).foregroundColor(.faint)
                    Spacer()
                    if installed {
                        Chip(pack.4 == nil ? "已就绪" : "已安装")
                        if let target = pack.4 {
                            if confirmingUninstall {
                                SmallBtn("确认卸载", primary: true) {
                                    store.uninstallConfirm = nil
                                    store.uninstallPack(target)
                                }
                                SmallBtn("取消") { store.uninstallConfirm = nil }
                            } else {
                                SmallBtn("卸载") { store.uninstallConfirm = pack.1 }
                                    .help("端到端卸载：停服务 + 删配置 + 删模型文件 + 引擎环境整体移除（零系统残留）")
                            }
                        }
                    } else if let target = pack.4, let preset = PackCard.packPresets[target] {
                        // 真安装：文件在盘 → 直接装机；不在 → 网关下载后自动装机
                        let dl = store.packDownloads[target]
                        if dl?.status == "building" {
                            Text(dl?.detail ?? "构建引擎中…")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.warnC)
                        } else if dl?.status == "downloading" || dl?.status == "installing" {
                            let pct: Int = {
                                guard let d = dl, let t = d.total, t > 0 else { return 0 }
                                return Int(Double(d.downloaded ?? 0) / Double(t) * 100)
                            }()
                            Text(dl?.status == "installing" ? "装机中…" : "下载 \(pct)%")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.accent)
                        } else if dl?.status == "error" {
                            SmallBtn("重试", primary: true) {
                                store.installPack(target, url: preset.0, filename: preset.1,
                                                  label: preset.2, engine: preset.3 ?? "")
                            }
                            Text("失败").font(.system(size: 10.5)).foregroundColor(.warnC)
                                .help(dl?.error ?? "")
                        } else {
                            SmallBtn("安装", primary: true) {
                                store.installPack(target, url: preset.0, filename: preset.1,
                                                  label: preset.2, engine: preset.3 ?? "")
                            }
                            .help(preset.3 == nil
                                  ? "从 hf-mirror 下载 GGUF 到 MacFabric/models 后自动写入 models.d；不自动启动"
                                  : "端到端装机：项目内构建 Metal 引擎 → 下载模型 → 写入 models.d（全程隔离，卸载整体移除）")
                        }
                    } else if pack.4 != nil {
                        // 无 preset：引擎未接入，诚实禁用
                        Text("待接入").font(.system(size: 10.5)).foregroundColor(.faint)
                            .help("该能力的引擎未接入，暂不可安装")
                    }
                }
            }
            .padding(12)
        }
    }
}

/// 云端接入：真数据 CRUD（GET/POST/DELETE /admin/cloud/providers + provider-models 五动作）
struct CloudView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !store.actionMessage.isEmpty {
                    Text(store.actionMessage).font(.system(size: 12))
                        .padding(8).frame(maxWidth: .infinity)
                        .background(Color.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                // 服务商列表（可展开模型策展）
                ForEach(store.cloud?.providers ?? [], id: \.name) { pv in
                    CloudProviderCard(store: store, pv: pv)
                }
                // 添加服务商表单
                CloudAddCard(store: store)
                HStack {
                    SmallBtn("重新发现全部模型") { store.cloudDiscover() }
                    if let total = store.cloud?.total_cloud_models {
                        Text("云端模型 \(total) 个").font(.system(size: 11)).foregroundColor(.faint)
                    }
                    Spacer()
                }
                Text("统一入口 :\(GW_PORT) 覆盖全部类型：/v1/chat/completions · /v1/messages · /v1/embeddings · /v1/audio/* · /v1/images/* · /ocr — 本地与云端候选共用同一调用面；API key 写入 secrets.env，YAML 只存 ${REF} 引用")
                    .font(.system(size: 11)).foregroundColor(.faint)
            }.padding(16)
        }
    }
}

struct CloudProviderCard: View {
    @ObservedObject var store: GatewayStore
    let pv: CloudProvider
    var expanded: Bool { store.cloudExpanded == pv.name }

    /// 一键拷贝：双协议统一入口 env 块（客户端零改动，换方言只换 BASE_URL 变量）
    func copyUnifiedConfig(_ pv: CloudProvider) {
        let lines = [
            "# MacFabric 统一入口（本机任一协议任选）",
            "export OPENAI_BASE_URL=\(GW_BASE)/v1",
            "export ANTHROPIC_BASE_URL=\(GW_BASE)",
            "# 服务商 \(pv.name)（已由网关聚合，客户端无需直连）",
            "#   OpenAI base:    \(pv.openai_base ?? "-")",
            "#   Anthropic base: \(pv.anthropic_base ?? "未配置（走网关翻译桥）")",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        store.actionMessage = "✅ 统一入口配置已复制到剪贴板"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(String(pv.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Color.accent.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundColor(.white)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(pv.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                            Chip("openai")
                            if (pv.anthropic_base ?? "").isEmpty == false { Chip("anthropic", color: Color.thJudge) }
                        }
                        Text(pv.openai_base ?? "").font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(.dim).lineLimit(1)
                    }
                    Spacer()
                    SmallBtn("拷贝配置") { copyUnifiedConfig(pv) }
                        .help("复制双协议统一入口配置（环境变量块）到剪贴板")
                    if pv.key_env_set == true { Chip("key ✓", color: Color.okC) } else { Chip("未设 key", color: Color.warnC) }
                    Chip("\(pv.routable_count ?? 0) 模型")
                    SmallBtn(expanded ? "收起" : "模型") { store.cloudExpanded = expanded ? nil : pv.name }
                    SmallBtn("测试") { store.cloudTestProvider(pv.name) }
                    // F3: 删除服务商（两击确认）
                    if store.cloudDeleteConfirm == pv.name {
                        SmallBtn("确认删除", primary: true) {
                            store.cloudDeleteConfirm = nil
                            store.cloudExpanded = nil
                            store.deleteCloudProvider(pv.name)
                        }
                        SmallBtn("取消") { store.cloudDeleteConfirm = nil }
                    } else {
                        SmallBtn("删除") { store.cloudDeleteConfirm = pv.name }
                    }
                }
                if expanded { cloudModelsSection }
            }
            .padding(12)
        }
        // 云端模型属性浮窗（行点开 → 配置/删除）
        .sheet(isPresented: Binding(
            get: { store.cloudEditorProvider == pv.name && store.cloudEditorSpec != nil },
            set: { if !$0 { store.closeCloudModelEditor() } })) {
            if let provider = store.cloudEditorProvider, let spec = store.cloudEditorSpec {
                CloudModelEditorSheet(store: store, provider: provider,
                                      spec: spec, enabled: store.cloudEditorEnabled)
            }
        }
    }

    // 模型策展：spec 列表 + 勾选启停 + 手填添加 + 移除 + VL 打标
    @ViewBuilder private var cloudModelsSection: some View {
        let specs = pv.model_specs ?? []
        let enabled = Set(pv.enabled_models ?? [])
        // 策展行 = spec 行 ∪ 已启用但未建 spec 的发现模型。发现模型 enable
        // 只进白名单（不建 model_specs），只渲染 specs 会让已启用模型在
        // 面板隐身、无法 VL 打标 — 合成行保证可见；点「标 VL」即落为真 spec
        let specIds = Set(specs.map { $0.id })
        let synthesized: [CloudModelSpec] = enabled.subtracting(specIds).sorted().map {
            CloudModelSpec(id: $0, manual: false, supports_vision: nil,
                           supports_tools: nil, context_window: nil,
                           max_output_tokens: nil, price_input: nil,
                           price_output: nil,
                           anthropic: (pv.anthropic_base ?? "").isEmpty == false)
        }
        let rows = specs + synthesized
        VStack(alignment: .leading, spacing: 4) {
            Text("模型策展 — 勾选入白名单（enabled_models）后可入池路由；点行进属性浮窗").font(.system(size: 11)).foregroundColor(.faint)
            ForEach(rows, id: \.id) { spec in
                HStack(spacing: 8) {
                    // 勾选 = enable/disable（可路由白名单）
                    SmallBtn(enabled.contains(spec.id) ? "已启用" : "未启用",
                             primary: enabled.contains(spec.id)) {
                        store.cloudModelAction(pv.name, action: enabled.contains(spec.id) ? "disable" : "enable",
                                               model: spec.id)
                    }
                    Text(spec.id).font(.system(size: 12.5)).foregroundColor(.ink)
                    // 协议可用性：openai 发现恒有；anthropic 协议按注册表
                    Chip("openai", color: Color.thLlm)
                    if spec.anthropic == true { Chip("anthropic", color: Color.thJudge) }
                    if spec.manual == true { Chip("手填") }
                    // 能力/属性状态 chips（编辑入口 = 点行 → 浮窗）
                    if spec.supports_vision == true { Chip("VL", color: Color.thVl) }
                    if spec.supports_tools == true { Chip("工具", color: Color.thLlm) }
                    if let cw = spec.context_window { Chip("ctx \(cw >= 1000 ? "\(cw/1000)k" : "\(cw)")") }
                    if let pi = spec.price_input, pi > 0, let po = spec.price_output, po > 0 {
                        Chip("¥\(String(format: "%g", pi))/\(String(format: "%g", po))")
                    }
                    Spacer()
                    SmallBtn("属性") {
                        store.openCloudModelEditor(provider: pv.name, spec: spec, enabled: enabled.contains(spec.id))
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.openCloudModelEditor(provider: pv.name, spec: spec, enabled: enabled.contains(spec.id))
                }
            }
            if rows.isEmpty {
                Text("暂无模型 — 点「测试」确认连通后，用下方输入框手填，或等待自动发现")
                    .font(.system(size: 11)).foregroundColor(.faint)
            }
            // 手填添加
            HStack(spacing: 8) {
                TextField("手填模型名（如 glm-5-air）",
                          text: Binding(get: { store.cloudAddModel }, set: { store.cloudAddModel = $0 }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                SmallBtn("添加", primary: true) {
                    let m = store.cloudAddModel.trimmingCharacters(in: .whitespaces)
                    guard !m.isEmpty else { return }
                    store.cloudModelAction(pv.name, action: "add", model: m)
                    store.cloudAddModel = ""
                }
            }
        }
        .padding(.top, 4)
    }
}

// 云端模型属性浮窗 — 点行打开：能力打标（VL/工具）+ 上下文/输出/价格属性 + 单独删除。
// 草稿状态在 GatewayStore（CLT 无 SwiftUI 宏，视图内 @State 不可用）。
struct CloudModelEditorSheet: View {
    var store: GatewayStore
    let provider: String
    let spec: CloudModelSpec
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("模型属性 — \(spec.id)").font(.system(size: 14, weight: .semibold)).foregroundColor(.ink)
                Spacer()
                SmallBtn("关闭") { store.closeCloudModelEditor() }
            }
            HStack(spacing: 6) {
                Chip("openai", color: Color.thLlm)
                if spec.anthropic == true { Chip("anthropic", color: Color.thJudge) }
                if spec.manual == true { Chip("手填") }
                Chip(enabled ? "白名单内" : "白名单外", color: enabled ? Color.okC : Color.warnC)
            }
            VStack(alignment: .leading, spacing: 8) {
                editorToggle("视觉（VL）— VL 请求调度排最前",
                             Binding(get: { store.editorVision }, set: { store.editorVision = $0 }))
                editorToggle("工具调用 — agent/函数调用基础能力",
                             Binding(get: { store.editorTools }, set: { store.editorTools = $0 }))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                editorField("上下文窗口（tokens）",
                            Binding(get: { store.editorCtx }, set: { store.editorCtx = $0 }))
                editorField("最大输出（tokens）",
                            Binding(get: { store.editorOut }, set: { store.editorOut = $0 }))
                HStack(spacing: 10) {
                    editorField("输入价 ¥/1M",
                                Binding(get: { store.editorPriceIn }, set: { store.editorPriceIn = $0 }))
                        .frame(maxWidth: 150)
                    editorField("输出价 ¥/1M",
                                Binding(get: { store.editorPriceOut }, set: { store.editorPriceOut = $0 }))
                        .frame(maxWidth: 150)
                }
                Text("留空 = 清除该属性；价格单位 ¥/百万 tokens").font(.system(size: 10.5)).foregroundColor(.faint)
            }
            Divider()
            HStack {
                if store.editorConfirmDelete {
                    SmallBtn("确认移除", primary: true) {
                        store.cloudModelAction(provider, action: "remove", model: spec.id)
                        store.closeCloudModelEditor()
                    }
                    SmallBtn("取消") { store.editorConfirmDelete = false }
                    Text("发现模型移除后不再重新出现").font(.system(size: 10.5)).foregroundColor(.faint)
                } else {
                    SmallBtn("移除此模型") { store.editorConfirmDelete = true }
                }
                Spacer()
                SmallBtn("保存", primary: true) { store.saveCloudModelEditor() }
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func editorToggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.system(size: 12)).foregroundColor(.ink) }
            .toggleStyle(.switch).controlSize(.small)
    }
    private func editorField(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5)).foregroundColor(.dim)
            TextField("", text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }
}

struct CloudAddCard: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("添加服务商 — OpenAI 兼容 base + API key（双协议统一出口 :\(GW_PORT)）")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                Text("只讲 OpenAI 方言的服务商开箱可用：网关把 /v1/messages（Anthropic）翻译成 OpenAI 调用再转发；服务商提供 Anthropic 协议端口时填第二行可直连免翻译")
                    .font(.system(size: 11)).foregroundColor(.faint)
                HStack(spacing: 8) {
                    TextField("Anthropic Base URL（可选，anthropic 协议端口直连）",
                              text: Binding(get: { store.cloudFormAnth }, set: { store.cloudFormAnth = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                }
                HStack(spacing: 8) {
                    TextField("名称（如 deepseek）",
                              text: Binding(get: { store.cloudFormName }, set: { store.cloudFormName = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    TextField("Base URL（如 https://api.deepseek.com/v1）",
                              text: Binding(get: { store.cloudFormBase }, set: { store.cloudFormBase = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    SecureField("API Key（可选，可后补）",
                                text: Binding(get: { store.cloudFormKey }, set: { store.cloudFormKey = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    SmallBtn("添加", primary: true) {
                        store.addCloudProvider()
                        store.cloudFormName = ""; store.cloudFormBase = ""
                        store.cloudFormKey = ""; store.cloudFormAnth = ""
                    }
                }
            }.padding(12)
        }
    }
}

/// 设置：真实系统数据（RAM/账本预算/版本/目录）；开关项标注接入批次，不假装可用
struct SettingsView: View {
    @ObservedObject var store: GatewayStore

    static let keyDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    @ViewBuilder private func keyRow(_ k: SecurityKeyInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: k.revoked ? "key.slash" : "key")
                .font(.system(size: 10)).foregroundColor(k.revoked ? .faint : .okC)
            Text(k.name).font(.system(size: 12)).foregroundColor(.ink)
            if k.revoked { Chip("已撤销", color: Color.faint) }
            if let ts = k.createdAt {
                Text(Self.keyDate.string(from: Date(timeIntervalSince1970: ts)))
                    .font(.system(size: 10.5)).foregroundColor(.faint)
            }
            Spacer()
            if !k.revoked {
                if store.securityKeyRevokeConfirm == k.id {
                    SmallBtn("确认撤销", primary: true) { store.revokeSecurityKey(k.id) }
                    SmallBtn("取消") { store.securityKeyRevokeConfirm = nil }
                } else {
                    SmallBtn("撤销") { store.securityKeyRevokeConfirm = k.id }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var ramGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
    private var reserveGB = 8   // MACFABRIC_RESERVE_MB 默认值（D2 裁决：全局唯一公式）
    private var budgetMB: Int? { store.snapshot?.status.gpu_total_mb }
    private var usedMB: Int? { store.snapshot?.status.gpu_used_mb }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 系统信息（App 直查，无网关依赖）
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("系统").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                        infoRow("芯片", ProcessInfo.processInfo.processorCount > 0 ? "\(ProcessInfo.processInfo.processorCount) 核" : "—")
                        infoRow("物理内存", "\(ramGB) GB")
                        infoRow("系统版本", osVersion)
                        infoRow("网关版本", store.snapshot != nil ? "在线" : "离线")
                    }.padding(12)
                }
                // 内存账本（全局唯一公式）
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("内存账本 — B = RAM − 保留（全局唯一公式，无第二道上限）")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                        infoRow("物理内存", "\(ramGB) GB")
                        infoRow("为系统保留", "\(reserveGB) GB（MACFABRIC_RESERVE_MB，改后重启网关生效）")
                        infoRow("账本预算 B", budgetMB.map { "\($0) MB" } ?? "—（网关离线）")
                        infoRow("当前已用", usedMB.map { "\($0) MB" } ?? "—")
                    }.padding(12)
                }
                // 开关项（诚实标注：已接线的可交互，未接线的保持禁用并说明）
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingRow(title: "开机时启动网关",
                                   desc: "需在终端执行 scripts/install-launchd.sh install 批准（v1.5 App 内一键）",
                                   on: false, disabled: true)
                        SettingRow(title: "仅本机监听",
                                   desc: "关闭后局域网设备可访问 :\(GW_PORT)（设计稿 v1.5 项，网关端点后接）",
                                   on: true, disabled: true)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("API Key 鉴权").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                                Text(store.securityEnforced
                                     ? "客户端需携带密钥调用 · 已登记 \(store.securityKeyCount) 把密钥"
                                     : "关闭中 — 本机任意客户端可直接调用 · 已登记 \(store.securityKeyCount) 把密钥")
                                    .font(.system(size: 11.5)).foregroundColor(.faint)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { store.securityEnforced },
                                set: { store.toggleSecurity($0) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(store.securityBusy)
                        }
                        .padding(.vertical, 8)
                        // 密钥管理（明文永不回显 — 新建时一次性展示）。
                        // 撤销密钥最多留 3 条痕 — 防撤销历史把设置页无限拉长（用户裁决）
                        if !store.securityKeys.isEmpty {
                            let active = store.securityKeys.filter { !$0.revoked }
                            let revokedAll = store.securityKeys.filter { $0.revoked }
                                .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
                            let revoked = revokedAll.prefix(3)
                            let hiddenRevoked = revokedAll.count - revoked.count
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(active) { k in
                                    keyRow(k)
                                }
                                ForEach(revoked) { k in
                                    keyRow(k)
                                }
                                if hiddenRevoked > 0 {
                                    Text("另有 \(hiddenRevoked) 把更早的已撤销密钥（已折叠，不影响鉴权）")
                                        .font(.system(size: 10.5)).foregroundColor(.faint)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        HStack {
                            SmallBtn("＋ 新建密钥", primary: true) { store.createSecurityKey() }
                                .disabled(store.securityBusy)
                            Text("客户端调用示例：Authorization: Bearer sk-iff-…")
                                .font(.system(size: 10.5)).foregroundColor(.faint)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        if let key = store.oneTimeKey {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("新密钥明文 — 仅显示这一次，请立即复制保存")
                                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.warnC)
                                HStack(spacing: 8) {
                                    Text(key)
                                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.ink)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    SmallBtn("复制") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(key, forType: .string)
                                        store.actionMessage = "✅ 密钥已复制到剪贴板"
                                    }
                                    SmallBtn("已保存") { store.oneTimeKey = nil }
                                }
                            }
                            .padding(10)
                            .background(Color.warnC.opacity(0.08))
                            .cornerRadius(8)
                            .padding(.vertical, 6)
                        }
                    }
                }
                // 目录与版本
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingRow(title: "模型目录",
                                   desc: "GGUF 模型文件所在位置（本机发现扫描此处）",
                                   path: "/Users/Apple/Documents/MacFabric/models")
                        SettingRow(title: "引擎",
                                   desc: "llama.cpp Metal 构建 · anthropic_native 透传",
                                   path: "engines/llama-b12361")
                    }
                }
                Text("开关项按设计稿分批接入：v1.5 网关端点落地后此页改为可交互")
                    .font(.system(size: 11)).foregroundColor(.faint)
            }.padding(16)
        }
    }

    @ViewBuilder private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundColor(.dim)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundColor(.ink)
        }
    }
}

struct SettingRow: View {
    let title: String
    let desc: String
    var on = false
    var path: String? = nil
    var button: String? = nil
    var disabled = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                Text(desc).font(.system(size: 11.5)).foregroundColor(.faint)
            }
            Spacer()
            if let path {
                Text(path).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim)
            }
            if let button {
                SmallBtn(button) {}
            } else if path == nil {
                Toggle("", isOn: .constant(on)).labelsHidden().toggleStyle(.switch)
                    .controlSize(.small).disabled(disabled).opacity(disabled ? 0.6 : 1)
            }
        }
        .padding(.vertical, 10)
        Divider().overlay(Color.lineC)
    }
}

// ─── G6: 首启向导（RAM 检测 → 预算确认 → 默认池 → 完成）─────────

final class WizardState: ObservableObject {
    @Published var page = 0   // 0 检测 / 1 预算 / 2 池 / 3 完成
}

struct WizardView: View {
    @ObservedObject var ws: WizardState
    let onFinish: () -> Void

    private var ramGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
    private var budgetGB: Int { ramGB - 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部进度
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i <= ws.page ? Color.accent : Color.black.opacity(0.12))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 28).padding(.top, 24)
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                switch ws.page {
                case 0: welcomePage
                case 1: budgetPage
                case 2: poolsPage
                default: donePage
                }
            }
            .padding(.horizontal, 28)
            Spacer()
            HStack {
                if ws.page > 0 { SmallBtn("上一步") { ws.page -= 1 } }
                Spacer()
                SmallBtn(ws.page == 3 ? "开始使用" : "下一步", primary: true) {
                    if ws.page == 3 { onFinish() } else { ws.page += 1 }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
        .frame(width: 520, height: 360)
        .background(Color.panel)
        .preferredColorScheme(.light)
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("欢迎用 MacFabric").font(.system(size: 20, weight: .bold)).foregroundColor(.ink)
            Text("Apple Silicon 小模型聚合平台 — 一个网关 :\(GW_PORT) 同时讲 OpenAI 与 Anthropic 两种方言，本地小模型与云端大模型同一调用面。")
                .font(.system(size: 13)).foregroundColor(.dim).fixedSize(horizontal: false, vertical: true)
            Label("检测到内存：\(ramGB) GB", systemImage: "memorychip")
                .font(.system(size: 13)).foregroundColor(.accent)
        }
    }

    private var budgetPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("内存账本").font(.system(size: 20, weight: .bold)).foregroundColor(.ink)
            Text("全局唯一公式：可加载预算 B = 物理内存 − 为系统保留")
                .font(.system(size: 13)).foregroundColor(.dim)
            HStack(spacing: 12) {
                budgetTile("物理内存", "\(ramGB) GB")
                Text("− 8 GB 保留").font(.system(size: 12)).foregroundColor(.faint)
                budgetTile("账本预算 B", "\(budgetGB) GB")
            }
            Text("所有模型准入、睡眠、驱逐都只看这一个数字；内存不足时会弹窗确认而不是静默失败。")
                .font(.system(size: 12)).foregroundColor(.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var poolsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("三个默认角色池").font(.system(size: 20, weight: .bold)).foregroundColor(.ink)
            Text("池按模型角色定义，本地失败自动落到云端，候选优先级随时可调：")
                .font(.system(size: 13)).foregroundColor(.dim)
            VStack(alignment: .leading, spacing: 8) {
                poolRow("iff/fast", "快速对话 · 低延迟优先", "qwen3-4b → glm-5")
                poolRow("iff/small", "轻量任务 · 意图分类", "qwen3-4b → glm-5-flash")
                poolRow("iff/premium", "高质量长文", "glm-5（云端）")
            }
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("一切就绪").font(.system(size: 20, weight: .bold)).foregroundColor(.ink)
            Text("• 网关已就绪 :\(GW_PORT)（OpenAI /v1/chat/completions · Anthropic /v1/messages）\n• 模型不默认启动 — 首个请求自动唤醒，约 3s\n• 能力包页可安装/卸载模型，模型池页可调路由优先级")
                .font(.system(size: 13)).foregroundColor(.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgetTile(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundColor(.accent)
            Text(k).font(.system(size: 11)).foregroundColor(.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }

    private func poolRow(_ name: String, _ use: String, _ chain: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.ink)
                .frame(width: 90, alignment: .leading)
            Text(use).font(.system(size: 12)).foregroundColor(.dim)
            Spacer()
            Text(chain).font(.system(size: 11, design: .monospaced)).foregroundColor(.faint)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
    }
}

// ─── AppKit 引导：菜单栏常驻 + 主窗口 ───────────────────────────

/// G3: 菜单栏 mini 织物条 — 预算水位分段 + 活跃/睡眠模型速览
struct MiniWeaveView: View {
    @ObservedObject var miniStore: GatewayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("MacFabric").font(.system(size: 11, weight: .semibold)).foregroundColor(.ink)
                Spacer()
                if let snap = miniStore.snapshot,
                   let total = snap.status.gpu_total_mb, total > 0 {
                    Text("账本 \(snap.status.gpu_used_mb ?? 0)/\(total) MB")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.faint)
                }
            }
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(fabricSegments(), id: \.0) { seg in
                        Rectangle().fill(seg.0)
                            .frame(width: max(geo.size.width * seg.1, 2))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(activeLabel).font(.system(size: 10)).foregroundColor(.dim).lineLimit(1)
        }
        .padding(10)
        .background(Color.panel)
    }

    private func fabricSegments() -> [(Color, Double)] {
        var segs: [(Color, Double)] = []
        let used = Double(miniStore.snapshot?.status.gpu_used_mb ?? 0)
        let total = Double(miniStore.snapshot?.status.gpu_total_mb ?? 0)
        if total > 0 { segs.append((Color.accent.opacity(0.75), min(used / total, 1.0))) }
        segs.append((Color.black.opacity(0.08), total > 0 ? max(1 - used / total, 0.02) : 1.0))
        return segs
    }

    private var activeLabel: String {
        let act = miniStore.models.filter { $0.active == true }.map(\.name)
        if act.isEmpty { return miniStore.gatewayUp ? "无活跃模型 · 网关在线" : "网关离线" }
        return "活跃: " + act.joined(separator: ", ")
    }
}

/// NSMenuItem.view 包装 — 菜单展开时刷新一次数据
final class MiniWeaveNSView: NSView {
    private let miniStore = GatewayStore()
    private var hosted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hosted else { return }
        hosted = true
        let hv = NSHostingView(rootView: MiniWeaveView(miniStore: miniStore))
        hv.frame = bounds
        hv.autoresizingMask = [.width, .height]
        addSubview(hv)
        miniStore.refresh()
        miniStore.fetchModels()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = GatewayStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var wizardWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)   // light 默认（用户偏好）
        buildMenuBarItem()
        store.onMemoryInsufficient = { [weak self] name, reason in
            self?.showMemoryDialog(name: name, reason: reason)
        }
        // G6: 首启向导（defaults 记忆，完成后不再出现）
        if !UserDefaults.standard.bool(forKey: "wizardDone") {
            showWizard()
        } else {
            showOverview()
        }
    }

    /// G6: 首启向导窗口 — RAM 检测 → 预算确认 → 默认池 → 完成
    private func showWizard() {
        let ws = WizardState()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                           styleMask: [.titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "MacFabric 首次设置"
        win.center()
        win.isMovableByWindowBackground = true
        win.contentView = NSHostingView(rootView: WizardView(ws: ws) { [weak self, weak win] in
            UserDefaults.standard.set(true, forKey: "wizardDone")
            win?.close()
            self?.showOverview()
        })
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        wizardWindow = win
    }

    /// G1 内存不足弹窗：预算与实测同位显示，确认后 force 超卖加载
    private func showMemoryDialog(name: String, reason: String) {
        let alert = NSAlert()
        alert.messageText = "内存不足"
        alert.informativeText = reason + "\n\n仍然加载可能导致系统卡顿或模型被 macOS 压缩/换页。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍然加载")
        guard let win = window else { return }
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertSecondButtonReturn {
                self.store.switchModel(name, force: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 主窗口可见性 → 轮询开关（关闭窗口即暂停 3s/30s 打点，重开即恢复）
    func windowWillClose(_ notification: Notification) { store.windowVisible = false }
    func windowDidBecomeKey(_ notification: Notification) { store.windowVisible = true }

    /// 最小化/关闭后从菜单栏、Dock 点击都能调回
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOverview() }
        return true
    }

    private func buildMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sharedwithyou",
                                     accessibilityDescription: "MacFabric")
        let menu = NSMenu()
        // G3: mini 织物条 + 活跃模型速览（设计稿菜单栏语义）
        let mini = NSMenuItem()
        mini.view = MiniWeaveNSView(frame: NSRect(x: 0, y: 0, width: 220, height: 58))
        menu.addItem(mini)
        menu.addItem(.separator())
        let overview = NSMenuItem(title: "打开总览", action: #selector(showOverview), keyEquivalent: "o")
        overview.target = self
        menu.addItem(overview)
        let dash = NSMenuItem(title: "打开网关面板 :\(GW_PORT)", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        menu.addItem(dash)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MacFabric",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showOverview() {
        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "MacFabric"
            win.center()
            win.delegate = self
            win.backgroundColor = NSColor(red: 0xf5/255, green: 0xf5/255, blue: 0xf8/255, alpha: 1)
            window = win
        }
        guard let win = window else { return }
        if win.isMiniaturized { win.deminiaturize(nil) }   // 修复：最小化后重新调出
        if win.contentView == nil || !(win.contentView is NSHostingView<MainWindowView>) {
            win.contentView = NSHostingView(rootView: MainWindowView(store: store))
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDashboard() {
        if let url = URL(string: GW_BASE + "/") { NSWorkspace.shared.open(url) }
    }
}

// ─── main ──────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
