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
    // 设计 token — 全部重接 DS 自适应色（批 2：跟随系统深色）
    static let desk = DS.desk
    static let panel = DS.panel
    static let chrome = DS.chrome
    static let glass = DS.glass
    static let lineC = DS.lineC
    static let ink = DS.ink
    static let dim = DS.dim
    static let faint = DS.faint
    static let accent = DS.accent
    static let okC = DS.okC
    static let errC = DS.errC
    static let warnC = DS.warnC
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

    /// 洗色三档（深色下改用白色低透明，避免黑洗色在深底不可见）
    static let washStrong = DS.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.16)
    static let wash = DS.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)
    static let washFaint = DS.adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.03, darkAlpha: 0.05)
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

/// 有类型的操作反馈（Task 10）：成功/进行中/警告/失败 — kind 在写入时确定，
/// 运行时绝不解析消息文本里的 emoji 做逻辑判断（emoji 仅是消息内的展示糖）
enum FeedbackKind: Equatable {
    case success, info, progress, warning, error
}

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
    var managed_by_pack: PackRef?
    var ledgerMode: String { ledger_mode ?? "on_demand" }
}
/// 统一架构（2026-11-16）：/models.managed_by_pack — 本地推理标注能力包来源
struct PackRef: Codable { var pack_id: String; var pack_version: String? }

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
/// B2：凭据账目/请求注入按档位隔离（dev|8998 / prod|8999）
let CURRENT_PROFILE: GatewayProfile = IS_DEV_PROFILE ? .dev : .prod

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
    var max_attempts: Int?      // Task 6 范围 1–10（新写入）；缺省 = 服务端默认 2
    var deadline_ms: Int?       // 1000–300000 ms；缺省 = 服务端默认 60000
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
    /// 真实能力标记（/models 发现载荷 capabilities.supports_vision）
    var capabilities: CloudModelCaps?
}
struct CloudModelCaps: Codable {
    var supports_vision: Bool?
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
// ── PK4: 能力包 Catalog-only 契约（/admin/packs/*，URL/hash 由后端提供）──
struct PackModelMeta: Codable { var id: String; var parameter_count_b: Int?; var quantization: String?; var license: String? }
struct PackRuntimeMeta: Codable { var engine: String?; var runtime_template: String? }
struct PackResources: Codable { var download_mb: Int?; var disk_mb: Int?; var peak_memory_mb: Int?; var gpu_role: String? }
struct PackLifecycle: Codable { var mode: String? }
struct PackExecMeta: Codable { var model_config_template: String?; var healthcheck: String? }
struct PackManifest: Codable {
    var pack_id: String; var pack_version: String; var capability: String
    var model: PackModelMeta?; var runtime: PackRuntimeMeta?
    var resources: PackResources?; var lifecycle: PackLifecycle?
    var execution: PackExecMeta?
}
struct PackCatalogEntry: Codable, Identifiable {
    var pack_id: String; var display_name: String; var summary: String
    var tags: [String]?; var capability: String; var builtin: Bool
    var risk_level: String; var manifest: PackManifest
    var id: String { pack_id }
}
struct PackCatalogPayload: Codable { var packs: [PackCatalogEntry] }
struct PackPoolRef: Codable { var pool: String; var candidate_id: String?; var model_name: String? }
struct PackStatusRec: Codable, Identifiable {
    var pack_id: String; var pack_version: String?; var status: String
    var stage: String?; var error: String?; var sandbox_degraded: Bool?
    var install_path: String?
    var installed_at: Int?; var affected_pools: [PackPoolRef]?
    var id: String { pack_id }
}
struct PackStatusPayload: Codable { var packs: [PackStatusRec] }
struct PackPreviewPayload: Codable { var affected_pools: [PackPoolRef]? }
struct PackPolicyPayload: Codable, Equatable { var max_model_parameters_b: Int; var system_reserved_memory_mb: Int }
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

// ── 监控台 v2（GET /api/monitor-report，PLAN v2 Task 7 契约）──
struct MonitorCoverage: Codable {
    var rows_scanned: Int?
    var pool_summary_rows: Int?
    var truncated: Bool?
}
struct MonitorTotals: Codable {
    var requests: Int?
    var success: Int?
    var success_rate: Double?
    var tokens_in: Int?
    var tokens_out: Int?
    var usage_unknown_rows: Int?
    var cost_estimate: Double?      // ¥（价格配置 ¥/1M tokens，评审 I5 对齐）
    var cost_coverage: String?
}
struct MonitorModelRow: Codable, Identifiable {
    var location: String?
    var provider: String?
    var model: String?
    var requests: Int?
    var success: Int?
    var success_rate: Double?
    var tokens_in: Int?
    var tokens_out: Int?
    var p50_ttft_ms: Double?
    var p95_ttft_ms: Double?
    var ttft_samples: Int?
    var p50_duration_ms: Double?
    var p95_duration_ms: Double?
    var duration_samples: Int?
    // 身份契约 (location, provider, model) — 跨 provider 同名不混合
    var id: String { "\(location ?? "-")|\(provider ?? "-")|\(model ?? "-")" }
}
struct MonitorBucket: Codable {
    var bucket_start: Double?
    var bucket_end: Double?
    var requests: Int?
    var success: Int?
    var tokens_in: Int?
    var tokens_out: Int?
}
struct MonitorPoolRow: Codable {
    var pool: String?
    var requests: Int?
    var success: Int?
    var final_targets: [String: Int]?
    var attempt_count: Int?
    var retry_count: Int?
    var fallback_count: Int?
    var summary_coverage: Double?
}
struct MonitorErrorRow: Codable {
    var `class`: String?
    var count: Int?
    var id: String { `class` ?? "other" }
}
struct MonitorReportPayload: Codable {
    var contract: String?
    var window: String?
    var scope: String?
    var since: Double?
    var until: Double?
    var collected_at: Double?
    var coverage: MonitorCoverage?
    var totals: MonitorTotals?
    var models: [MonitorModelRow]?
    var series: [MonitorBucket]?
    var pools: [MonitorPoolRow]?
    var errors: [MonitorErrorRow]?
}
// Task 6 运行态（GET /admin/model-pools/runtime）— 池候选健康的数据源：
// 请求是否真的在调用（last_attempt）与冷却/半开（cooling），不是"注册表存在"
struct PoolCooling: Codable { var remaining_s: Double?; var reason: String?; var probing: Bool? }
struct PoolLastAttempt: Codable { var ok: Bool?; var status: Int?; var age_s: Double? }
struct PoolRuntimeCand: Codable {
    var id: String?
    var kind: String?
    var target: String?
    var active: Bool?
    var cooling: PoolCooling?
    var last_attempt: PoolLastAttempt?
}
struct PoolRuntimeCands: Codable { var candidates: [PoolRuntimeCand]? }
struct PoolRuntimePayload: Codable { var revision: Int?; var pools: [String: PoolRuntimeCands]? }

final class GatewayStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var gatewayUp = false
    @Published var tab = 0
    @Published var prompt = "你好，介绍一下你自己"
    @Published var reply = ""
    @Published var busy = false
    @Published var models: [ModelItem] = []
    @Published var curve: [CurvePoint] = []
    /// 操作反馈横幅（批 1 TOP5 状态可信）：错误持久显示 — 新反馈或用户清除才消失，
    /// 不再 5s 自灭；成功/进行中仍 5s 自动消退（避免陈旧 ✅ 误导）
    func notify(_ kind: FeedbackKind, _ text: String) {
        actionKind = kind
        actionMessage = text
        msgClear?.cancel(); msgClear = nil
        guard kind != .error else { return }
        let work = DispatchWorkItem { [weak self] in self?.actionMessage = "" }
        msgClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
    @Published var actionKind: FeedbackKind = .info
    @Published var actionMessage = ""
    private var msgClear: DispatchWorkItem?

    /// 用户主动清除反馈横幅
    func clearActionMessage() {
        msgClear?.cancel(); msgClear = nil
        actionMessage = ""
    }
    @Published var hubExpanded = ""
    /// B3：本地推理页选中行（instanceID；CLT 无 @State 宏，存 store）
    @Published var inferenceSelectedID: String? = nil
    /// B3：模型服务页选中行（id = instanceID 或 cloud|<upstream-id>）
    @Published var hubSelectedID: String? = nil
    /// B3：能力包页选中行（id = packID|variant）
    @Published var packSelectedID: String? = nil
    /// 能力包页类型筛选（""=全部；值为 PrimaryType.displayName）
    @Published var packTypeFilter: String = ""
    /// B3：页面实测宽度（WidthReader 上报；CLT 无 @State 宏，状态集中 store）
    @Published var contentWidths: [String: CGFloat] = [:]
    @Published var pools: PoolsPayload?
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
    // ── 监控台 v2（Task 8）：/api/monitor-report 消费 ──
    @Published var monitorWindow = "24h"       // 用户当前选择
    @Published var monitorScope = "all"
    @Published var monitorReport: MonitorReportPayload?
    /// 展示中报告自己的区间/来源 — 筛选切换后旧数据保留展示但用旧区间标注，
    /// 不套新标签（QA 场景 3）
    @Published var monitorReportWindow = "24h"
    @Published var monitorReportScope = "all"
    @Published var monitorLoading = false
    @Published var monitorSelectedModel: String?   // 模型表选中行（身份 id）
    @Published var monitorPoolExpanded: String? = nil  // 池卡详情展开
    @Published var monitorRuntime: PoolRuntimePayload? // Task 6 运行态（冷却/最近尝试）
    private var monitorGeneration = 0          // 请求代数：旧响应不得覆盖新选择
    private var monitorTimer: Timer?
    // ── PK4: 能力包 Catalog（v2，Catalog-only）──
    @Published var packCatalog: PackCatalogPayload?
    @Published var packStatus: PackStatusPayload?
    @Published var packPolicy: PackPolicyPayload?
    // 设置页策略表单草稿（CLT 无 SwiftUI 宏，视图内 @State 不可用 — 既有约束）
    @Published var packMaxBDraft = "4"
    @Published var packReservedMBDraft = "8192"
    // ── 用户扩展能力包（统一架构 2026-11-16：填链接 → 网关校验链）──
    @Published var customName = ""
    @Published var customURL = ""
    @Published var customCap = "llm"
    @Published var customSHA = ""
    @Published var customBusy = false

    func submitCustomPack() {
        guard !customBusy else { return }
        var body: [String: Any] = [
            "name": customName.trimmingCharacters(in: .whitespaces),
            "url": customURL.trimmingCharacters(in: .whitespaces),
            "capability": customCap]
        let sha = customSHA.trimmingCharacters(in: .whitespaces)
        if !sha.isEmpty { body["sha256"] = sha }
        customBusy = true
        var req = adminRequest("/admin/packs/custom", timeoutInterval: 15)
        guard attachAdminToken(&req) else {
            customBusy = false
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.customBusy = false
                if (200..<300).contains(code) {
                    self?.notify(.success, "✅ 自定义包已提交 — 校验链执行中（下载→格式→真引擎试加载），进度看卡片")
                    self?.customName = ""; self?.customURL = ""; self?.customSHA = ""
                    self?.fetchPackStatus()
                } else {
                    self?.notify(.error, "❌ 自定义包被拒(\(code)): \(detail.prefix(200))")
                }
            }
        }.resume()
    }
    // ── API Key 鉴权（设置页接线 — /admin/security/*）──
    @Published var securityEnforced = false
    /// B2 真实鉴权状态机：loading/loaded(stale)/unavailable — 5xx/超时/畸形 ≠ 未启用
    @Published var securityState: SecurityState = .loading
    private var securityStatusStore = SecurityStatusStore()
    private var securityGeneration = 0
    /// 凭据：会话 key 优先，其次 Keychain（按档位隔离账目）；不静默建 key
    var credentialStore: GatewayCredentialStore = KeychainCredentialStore()
    @Published var sessionAPIKey: String? = nil
    var currentAPIKey: String? {
        if let sessionAPIKey, !sessionAPIKey.isEmpty { return sessionAPIKey }
        return (try? credentialStore.load(profile: CURRENT_PROFILE)) ?? nil
    }
    var authPresentation: AuthPresentation {
        switch securityState {
        case .loaded(let snap, _): snap.presentation
        case .loading, .unavailable: .unknown
        }
    }
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

    // ── 网关守护（设置页"开机时启动网关"Toggle — spec 2026-11-17-gateway-daemon-toggle.md）──
    // 使能语义 = plist 存在（登录自启注册即已使能；进程瞬时波动不影响开关呈现）。
    // 红线：只按精确 label bootout/bootstrap，严禁全局 pkill proxy.handler。
    @Published var daemonInstalled = false
    @Published var daemonRunningPID: String? = nil
    @Published var daemonBusy = false
    /// QA 注入（沙箱 e2e 用 env 覆盖 label/program；生产进程不带这些环境变量）
    static var daemonQALabel: String? = ProcessInfo.processInfo.environment["MACFABRIC_DAEMON_LABEL"]
    static var daemonQAProgramArgs: [String]? = {
        guard let raw = ProcessInfo.processInfo.environment["MACFABRIC_DAEMON_PROGRAM_ARGS"] else { return nil }
        return raw.components(separatedBy: "\u{1f}")
    }()
    private var daemonLabel: String { Self.daemonQALabel ?? GatewayDaemon.defaultLabel }
    private var daemonPlistPath: String {
        NSString(string: "~/Library/LaunchAgents/\(daemonLabel).plist").expandingTildeInPath
    }

    /// Settings onAppear / 操作后刷新：plist 存在性 + launchctl print 三态
    func refreshDaemonState() {
        let fm = FileManager.default
        let plistExists = fm.fileExists(atPath: daemonPlistPath)
        let args = GatewayDaemon.printArgs(uid: String(getuid()), label: daemonLabel)
        let out = runLaunchctl(args)
        DispatchQueue.main.async {
            switch GatewayDaemon.state(plistExists: plistExists, launchctlPrint: out) {
            case .notInstalled:
                self.daemonInstalled = false; self.daemonRunningPID = nil
            case .stopped:
                self.daemonInstalled = true; self.daemonRunningPID = nil
            case .running(let pid):
                self.daemonInstalled = true; self.daemonRunningPID = pid
            }
        }
    }

    /// 开：校验 prod venv → 写 plist → bootstrap（已加载则跳过 bootstrap）
    func enableDaemon() {
        guard !daemonBusy else { notify(.warning, "⚠️ 上一操作进行中，请稍候"); return }
        daemonBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let prodDir: String
            let modelsDir: String
            let logPath: String
            if Self.daemonQALabel != nil {
                // 沙箱 e2e：目录走 env（不触生产路径）
                let env = ProcessInfo.processInfo.environment
                prodDir = env["MACFABRIC_DAEMON_PROD_DIR"] ?? "/tmp"
                modelsDir = env["MACFABRIC_DAEMON_MODELS_DIR"] ?? "/tmp"
                logPath = env["MACFABRIC_DAEMON_LOG"] ?? "/tmp/daemon-qa.log"
            } else {
                prodDir = NSString(string: "~/Library/MacFabric/prod").expandingTildeInPath
                modelsDir = NSString(string: "~/.inferfabric/models.d").expandingTildeInPath
                logPath = NSString(string: "~/.inferfabric/logs/gateway.launchd.log").expandingTildeInPath
            }
            var failure: String? = nil
            if Self.daemonQALabel == nil {
                let fm = FileManager.default
                if !fm.fileExists(atPath: "\(prodDir)/.venv/bin/python") {
                    failure = "未找到生产安装（\(prodDir)/.venv/bin/python 不存在）— 请先执行 scripts/release-install.sh"
                }
                if failure == nil, !fm.fileExists(atPath: modelsDir) {
                    failure = "未找到模型配置目录（\(modelsDir)）— 请先执行 scripts/release-install.sh"
                }
            }
            if failure == nil {
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: (daemonPlistPath as NSString).deletingLastPathComponent),
                    withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: (logPath as NSString).deletingLastPathComponent),
                    withIntermediateDirectories: true)
                let xml = GatewayDaemon.plistXML(prodDir: prodDir, modelsDir: modelsDir, logPath: logPath,
                                                 label: self.daemonLabel, programArgs: Self.daemonQAProgramArgs)
                do {
                    try xml.write(toFile: self.daemonPlistPath, atomically: true, encoding: .utf8)
                } catch {
                    failure = "写入 plist 失败: \(error.localizedDescription)"
                }
            }
            if failure == nil {
                // 已加载则跳过 bootstrap（重复 bootstrap 会报 9: Bundle already loaded）
                if self.runLaunchctl(GatewayDaemon.printArgs(uid: String(getuid()), label: self.daemonLabel)) == nil {
                    _ = self.runLaunchctl(GatewayDaemon.bootstrapArgs(uid: String(getuid()), plistPath: self.daemonPlistPath))
                }
            }
            DispatchQueue.main.async {
                self.daemonBusy = false
                if let failure {
                    self.notify(.error, "❌ \(failure)")
                } else {
                    self.notify(.success, "✅ 网关守护已使能 — 登录时自启、崩溃自愈")
                }
                self.refreshDaemonState()
            }
        }
    }

    /// 关：bootout（按精确 label）→ 删 plist。调用方必须先经确认对话框（停生产网关）。
    func disableDaemon() {
        guard !daemonBusy else { notify(.warning, "⚠️ 上一操作进行中，请稍候"); return }
        daemonBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.runLaunchctl(GatewayDaemon.bootoutArgs(uid: String(getuid()), label: self.daemonLabel))
            try? FileManager.default.removeItem(atPath: self.daemonPlistPath)
            DispatchQueue.main.async {
                self.daemonBusy = false
                self.notify(.success, "✅ 网关守护已停用 — 登录不再自启；如需恢复请重新打开开关")
                self.refreshDaemonState()
            }
        }
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            return p.terminationStatus == 0 ? out : nil
        } catch {
            return nil
        }
    }

    private var base: URL { URL(string: GW_BASE)! }
    private var timer: Timer?
    private var curveTimer: Timer?
    /// 控制面门禁（批 1 TOP1）：admin/控制路由请求注入 X-Admin-Token
    /// （双账目：独立 Keychain service；born 迁移读 secrets.env 一次转存）
    let adminTokens = AdminTokenCredentialStore(
        backing: KeychainCredentialStore(service: AdminTokenCredentialStore.serviceName))
    @Published var adminTokenReady = false
    @Published var adminTokenMissing = false
    /// 主窗口可见性 — 菜单栏常驻应用，窗口关闭后暂停轮询（空转打点无意义；
    /// 菜单栏迷你条是独立 store，打开菜单时刷新一次）
    var windowVisible = true

    init() {
        bootstrapAdminToken()
        refresh(); fetchModels(); fetchCurve(); fetchPools(); fetchCloud(); scanLocalModels(); fetchMetrics(); fetchSecurityStatus(); fetchPackCatalog()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.windowVisible else { return }
            self.refresh(); self.fetchModels(); self.fetchSecurityStatus()
            self.fetchPools()   // 池可能被其它页面/服务端联动改变（如卸载触发的候选清除）
            if self.tab == 5 { self.fetchPackStatus() }   // PK4: 能力包页可见时轮询安装态
        }
        curveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.windowVisible else { return }
            self.fetchCurve(); self.fetchCloud()   // 云端发现/注册表周期性变化
        }
        // 监控台 15s 刷新（建议值）— 仅监控页可见时；离页/关窗由 windowVisible
        // 与 tab==4 双闸暂停，不空转查询。同查询短 TTL 网关单飞兜底。
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, self.windowVisible, self.tab == 4 else { return }
            self.fetchMonitorReport()
            self.fetchPoolRuntime()
        }
    }

    /// born 迁移：Keychain 无 admin token 时读档位 secrets.env（prod ~/.inferfabric /
    /// dev ~/.inferfabric-dev）转存；失败如实置 adminTokenMissing（UI 提示，
    /// 绝不假装已配置）。
    private func bootstrapAdminToken() {
        let outcome = AdminTokenBootstrap.migrate(
            store: adminTokens,
            fileReader: AdminTokenBootstrap.secretsFileReader,
            profile: CURRENT_PROFILE)
        switch outcome {
        case .migrated, .alreadyStored:
            adminTokenReady = true; adminTokenMissing = false
        case .absent, .failed:
            adminTokenReady = false; adminTokenMissing = true
        }
    }

    /// 统一出口（TOP2）：admin 请求就地挂 X-Admin-Token。token 缺失返回 false —
    /// 轮询静默跳过，用户动作显式报错；绝不静默发无 token 请求。
    /// 兜底：网关可能晚于 App 首次 born（App 常驻而网关刚装好）— 重试一次迁移。
    @discardableResult
    private func attachAdminToken(_ request: inout URLRequest) -> Bool {
        if let token = adminTokens.load(profile: CURRENT_PROFILE), !token.isEmpty {
            request = AdminRequestAuthorizer.attach(request, profile: CURRENT_PROFILE, token: token)
            return true
        }
        guard case .migrated = AdminTokenBootstrap.migrate(
            store: adminTokens,
            fileReader: AdminTokenBootstrap.secretsFileReader,
            profile: CURRENT_PROFILE),
            let token = adminTokens.load(profile: CURRENT_PROFILE), !token.isEmpty else {
            return false
        }
        request = AdminRequestAuthorizer.attach(request, profile: CURRENT_PROFILE, token: token)
        return true
    }

    /// admin 请求构造（统一 base/超时口径；inout 挂 token 由 attachAdminToken 负责）
    private func adminRequest(_ path: String, timeoutInterval: TimeInterval = 30) -> URLRequest {
        URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeoutInterval)
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

    /// 池配置拉取代数（终审 I8）：旧 GET 响应不得覆盖新 CAS 后的状态 —
    /// mutation 完成触发的拉取与 3s 轮询可能交错，仅应用最新代数响应。
    private var poolsFetchGeneration = 0

    func fetchPools(completion: (() -> Void)? = nil) {
        poolsFetchGeneration += 1
        let gen = poolsFetchGeneration
        var req = adminRequest("/admin/model-pools")
        guard attachAdminToken(&req) else {
            DispatchQueue.main.async { completion?() }
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let pl = try? JSONDecoder().decode(PoolsPayload.self, from: data) else {
                DispatchQueue.main.async { completion?() }
                return
            }
            DispatchQueue.main.async {
                if gen == self.poolsFetchGeneration {   // 旧响应丢弃
                    self.pools = pl
                }
                completion?()
            }
        }.resume()
    }

    /// F1: 候选操作统一入口 — 每次现取 raw（旧版缓存导致网关重启后 ↑↓ 静默失效）。
    /// mutate(raw) 在后台线程改 priorities/candidates，POST CAS 回写。
    /// Task 9：mutation 按用户意图顺序**串行**执行（连点排序不交错）；
    /// 409（连点/竞态）自动以新 revision 重放同一语义操作（字段级修改在
    /// 新基点上做，不覆盖他人配置），重放失败则显式报错回滚可解释。
    func mutatePools(_ mutate: @escaping (inout [String: Any]) -> Void,
                     okMsg: String, failPrefix: String) {
        enqueuePoolMutation {
            self.postPoolsMutation(mutate, okMsg: okMsg, failPrefix: failPrefix, allowRetry: true)
        }
    }

    // 池 mutation 串行队列：入队后逐个执行，前一个完成（含失败/重放入队）
    // 才跑下一个 — 意图顺序与点击顺序一致
    private var poolMutationQueue: [() -> Void] = []
    private var poolMutationRunning = false

    private func enqueuePoolMutation(_ work: @escaping () -> Void) {
        poolMutationQueue.append(work)
        drainPoolMutations()
    }

    private func drainPoolMutations() {
        guard !poolMutationRunning, !poolMutationQueue.isEmpty else { return }
        poolMutationRunning = true
        poolMutationQueue.removeFirst()()
    }

    private func poolMutationDone() {
        poolMutationRunning = false
        drainPoolMutations()
    }

    private func postPoolsMutation(_ mutate: @escaping (inout [String: Any]) -> Void,
                                   okMsg: String, failPrefix: String, allowRetry: Bool) {
        guard let url = URL(string: "\(GW_BASE)/admin/model-pools") else { poolMutationDone(); return }
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var raw = obj["raw"] as? [String: Any],
                  let rev = obj["revision"] as? Int else {
                DispatchQueue.main.async {
                    // TOP5 状态可信：离线/凭据未就绪/其它 — 不笼统报"读取失败"
                    if self?.gatewayUp != true {
                        self?.notify(.error, "❌ 网关离线 — 池配置未读取，网关启动后重试")
                    } else if (resp as? HTTPURLResponse)?.statusCode == 401 {
                        self?.notify(.error, "❌ 管理凭据未就绪（401）— 重启 App 重试 born 迁移")
                    } else {
                        self?.notify(.error, "❌ 池配置读取失败(\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
                    }
                    self?.poolMutationDone()
                }
                return
            }
            mutate(&raw)
            raw["expected_revision"] = rev
            var req = URLRequest(url: url, timeoutInterval: 30)
            guard self.attachAdminToken(&req) else {
                DispatchQueue.main.async {
                    self.notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
                    self.poolMutationDone()
                }
                return
            }
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: raw)
            URLSession.shared.dataTask(with: req) { [weak self] data2, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = data2.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    if code == 409 && allowRetry {
                        // revision 过期（连点/与轮询竞态）— 重放排到队尾按序执行
                        // （同语义操作在新基点上重做，不静默覆盖他人字段级修改）
                        self?.poolMutationDone()
                        self?.enqueuePoolMutation {
                            self?.postPoolsMutation(mutate, okMsg: okMsg,
                                                    failPrefix: failPrefix, allowRetry: false)
                        }
                        return
                    }
                    self?.notify((200..<300).contains(code) ? .success : .error,
                        (200..<300).contains(code) ? okMsg : "❌ \(failPrefix)(\(code)): \(body.prefix(100))")
                    self?.fetchPools()
                    self?.poolMutationDone()
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

    // ── 池候选拖拽排序（onDrag/onDrop）──
    // Task 9：poolDragging 携带 "pool|candidate" 双身份 — 跨池拖放被
    // DropDelegate 拒绝（同 id 候选可存在于多个池，只带 id 会误操作其他池）；
    // 取消（落到容器空白处/切换页签）清理高亮
    @Published var poolDragging: String? = nil

    func cancelPoolDrag() { poolDragging = nil }

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

    /// F8: 单池 enabled 开关（服务端字段级原子修改 + expected_revision CAS；
    /// 409 重取基点重放一次 — 网关重启 revision 重置后同样以新基点重建，
    /// 不存在"永久忽略较小 revision"）
    func togglePool(_ name: String, enabled: Bool, retried: Bool = false) {
        guard let rev = pools?.revision else { return }
        var req = adminRequest("/admin/model-pools/toggle", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pool": name, "enabled": enabled, "expected_revision": rev])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if code == 409 && !retried {
                    self.fetchPools {
                        self.togglePool(name, enabled: enabled, retried: true)
                    }
                    return
                }
                self.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code) ? "✅ fabric-\(name) 已\(enabled ? "启用" : "停用")" : "❌ 开关失败(\(code)): \(body.prefix(100))")
                self.fetchPools()
            }
        }.resume()
    }

    // ── 池高级设置（Task 6 max_attempts/deadline_ms 接入；Task 9 一致性）──
    // 范围与服务端严格校验一致：1–10 次 / 1000–300000ms。CAS 走 mutatePools
    // （raw 基底改字段，未修改字段原样保留，不重建有损配置）
    @Published var poolAdvExpanded: String? = nil
    @Published var poolAdvAttempts = ""
    @Published var poolAdvDeadline = ""
    @Published var poolAdvError = ""

    func togglePoolAdvanced(_ name: String, def: PoolDef) {
        if poolAdvExpanded == name {
            poolAdvExpanded = nil
            return
        }
        poolAdvExpanded = name
        poolAdvAttempts = ""      // 留空 = 不修改（占位提示当前值）
        poolAdvDeadline = ""
        poolAdvError = ""
    }

    func savePoolAdvanced(_ name: String) {
        let aRaw = poolAdvAttempts.trimmingCharacters(in: .whitespaces)
        let dRaw = poolAdvDeadline.trimmingCharacters(in: .whitespaces)
        var aSet: Int? = nil; var aTouch = false
        var dSet: Int? = nil; var dTouch = false
        if !aRaw.isEmpty {
            guard let n = Int(aRaw), (1...10).contains(n) else {
                poolAdvError = "max_attempts 需为 1–10 的整数（当前输入保留）"; return
            }
            aSet = n; aTouch = true
        }
        if !dRaw.isEmpty {
            guard let n = Int(dRaw), (1000...300000).contains(n) else {
                poolAdvError = "deadline_ms 需为 1000–300000 的整数（当前输入保留）"; return
            }
            dSet = n; dTouch = true
        }
        guard aTouch || dTouch else { poolAdvError = "两个字段都为空 — 无可保存的修改"; return }
        poolAdvError = ""
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var pc = poolsCfg[name] as? [String: Any] else { return }
            if let n = aSet { pc["max_attempts"] = n }
            if let n = dSet { pc["deadline_ms"] = n }
            poolsCfg[name] = pc
            raw["pools"] = poolsCfg
        }, okMsg: "✅ fabric-\(name) 池参数已更新", failPrefix: "池参数保存失败")
    }

    /// 恢复服务端默认：删除这两个键（服务端缺省 max_attempts=2 / deadline_ms=60000）
    func resetPoolAdvanced(_ name: String) {
        mutatePools({ raw in
            guard var poolsCfg = raw["pools"] as? [String: Any],
                  var pc = poolsCfg[name] as? [String: Any] else { return }
            pc.removeValue(forKey: "max_attempts")
            pc.removeValue(forKey: "deadline_ms")
            poolsCfg[name] = pc
            raw["pools"] = poolsCfg
        }, okMsg: "✅ fabric-\(name) 池参数已恢复默认", failPrefix: "池参数恢复失败")
    }

    /// F2: 能力包卸载 = 停服务 + 删 models.d YAML + 热重载
    // ── PK4: 能力包 Catalog-only API（App 只提交 pack_id，URL/hash 后端定）──

    func fetchPackCatalog() {
        var req = adminRequest("/admin/packs/catalog")
        guard attachAdminToken(&req) else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let p = try? JSONDecoder().decode(PackCatalogPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.packCatalog = p }
        }.resume()
    }

    func fetchPackStatus() {
        var req = adminRequest("/admin/packs/status")
        guard attachAdminToken(&req) else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let p = try? JSONDecoder().decode(PackStatusPayload.self, from: data) else { return }
            DispatchQueue.main.async {
                self.packStatus = p
                // installed/failed 终态 → 模型列表可能变化（受控 YAML 生成）
                if p.packs.contains(where: { ["installed", "failed"].contains($0.status) }) { self.fetchModels() }
            }
        }.resume()
    }

    func fetchPackPolicy() {
        var req = adminRequest("/admin/packs/policy")
        guard attachAdminToken(&req) else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let p = try? JSONDecoder().decode(PackPolicyPayload.self, from: data) else { return }
            DispatchQueue.main.async {
                self.packPolicy = p
                // 草稿回填（fetch 仅页面 onAppear 触发，不与用户编辑竞争）
                self.packMaxBDraft = String(p.max_model_parameters_b)
                self.packReservedMBDraft = String(p.system_reserved_memory_mb)
            }
        }.resume()
    }

    func savePackPolicy(_ maxB: Int, _ reservedMB: Int) {
        var req = adminRequest("/admin/packs/policy", timeoutInterval: 15)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "max_model_parameters_b": maxB, "system_reserved_memory_mb": reservedMB])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                if (200..<300).contains(code) {
                    self?.notify(.success, "✅ 策略已保存（安装预检 + 内存账本即时共用，无需重启）")
                    self?.fetchPackPolicy()
                } else {
                    self?.notify(.error, "❌ 策略保存失败(\(code)): \(body.prefix(160))")
                }
            }
        }.resume()
    }

    /// 安装：只提交 pack_id（Catalog-only 裁决）；进度看卡片阶段文案
    func startPackInstall(_ packId: String, _ label: String) {
        notify(.progress, "\(label) 安装中…")
        var req = adminRequest("/admin/packs/install", timeoutInterval: 15)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pack_id": packId])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                if code == 202 {
                    self?.notify(.info, "\(label) 开始安装…进度看卡片")
                    self?.fetchPackStatus()
                } else {
                    self?.notify(.error, "❌ 安装请求失败(\(code)): \(body.prefix(160))")
                }
            }
        }.resume()
    }

    /// 卸载：先预览受影响池 → 全局确认框（空列表也走确认，防误删）→ confirmed 执行
    func previewPackUninstall(_ packId: String, _ label: String) {
        var comps = URLComponents(string: "\(GW_BASE)/admin/packs/uninstall-preview")!
        comps.queryItems = [URLQueryItem(name: "pack_id", value: packId)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                guard code == 200, let self,
                      let p = try? JSONDecoder().decode(PackPreviewPayload.self, from: data ?? Data()) else {
                    self?.notify(.error, "❌ 预览失败(\(code)): \(body.prefix(160))")
                    return
                }
                let pools = p.affected_pools ?? []
                let poolList = pools.map { $0.pool }.sorted().joined(separator: "、")
                let text = pools.isEmpty
                    ? "卸载能力包「\(label)」？将停止进程、删除配置与全部包文件（不可恢复）。"
                    : "卸载能力包「\(label)」？以下模型池的候选将被清除：\(poolList)。\n进程停止、配置与包文件全部删除（不可恢复）。"
                self.confirm(text) { self.uninstallPackConfirmed(packId, label) }
            }
        }.resume()
    }

    func uninstallPackConfirmed(_ packId: String, _ label: String) {
        notify(.progress, "卸载 \(label) 中…")
        var req = adminRequest("/admin/packs/uninstall", timeoutInterval: 60)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pack_id": packId, "confirmed": true])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                // 卸载是跨页面事件：模型列表、池（服务端联动清除）、本地扫描即时刷新
                self?.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code) ? "✅ \(label) 已卸载" : "❌ 卸载失败(\(code)): \(body.prefix(160))")
                self?.fetchModels(); self?.fetchPools()
                self?.scanLocalModels(); self?.fetchPackStatus()
            }
        }.resume()
    }

    func fetchCloud() {
        var req = adminRequest("/admin/cloud/providers")
        guard attachAdminToken(&req) else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let cp = try? JSONDecoder().decode(CloudPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.cloud = cp }
        }.resume()
    }

    /// 设置页：鉴权开关状态（30s 轮询 + 操作后即时刷新；B2：代际 + 状态机，失败 ≠ 未启用）
    func fetchSecurityStatus() {
        securityGeneration += 1
        let gen = securityGeneration
        var req = adminRequest("/admin/security/status")
        guard attachAdminToken(&req) else { return }   // 凭据未就绪：轮询跳过（呈现"状态未知"，不假装）
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            let outcome: Result<SecuritySnapshot, StatusFetchError> = {
                if let snap = SecurityGatewayStatus.parse(data: data, response: resp, error: err) { return .success(snap) }
                if let e = err { return .failure((e as NSError).code == NSURLErrorTimedOut ? .timeout : .transport) }
                if let code = (resp as? HTTPURLResponse)?.statusCode { return .failure(.http(code)) }
                return .failure(.malformed)
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                self.securityStatusStore.apply(gen, outcome)
                self.securityState = self.securityStatusStore.state
                if case .success(let snap) = outcome {
                    self.securityEnforced = snap.enforced
                }
                // 密钥清单仅在 2xx 成功响应时刷新（失败不清理旧清单）
                guard case .success = outcome, let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
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
        guard !securityBusy else { notify(.warning, "⚠️ 上一操作进行中，请稍候"); return }
        securityBusy = true
        var req = adminRequest("/admin/security/keys", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            securityBusy = false
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
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
                    self.notify(.success, "✅ 新密钥已生成 — 明文仅显示这一次，请立即复制")
                } else {
                    self.notify(.error, "❌ 新建密钥失败(\(code)): \(raw.prefix(100))")
                }
                self.fetchSecurityStatus()
            }
        }.resume()
    }

    /// 设置页：撤销指定 key（两击确认）
    func revokeSecurityKey(_ id: String) {
        guard !securityBusy else { notify(.warning, "⚠️ 上一操作进行中，请稍候"); return }
        securityBusy = true
        var req = adminRequest("/admin/security/keys/revoke", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            securityBusy = false
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.securityBusy = false
                self.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code) ? "✅ 密钥已撤销" : "❌ 撤销失败(\(code))")
                self.securityKeyRevokeConfirm = nil
                self.fetchSecurityStatus()
            }
        }.resume()
    }

    /// 设置页：一键启用/关闭鉴权。启用时网关返回的首把明文 key 存 oneTimeKey
    /// （库内只存摘要 — 不弹这次就再也拿不到明文）。
    func toggleSecurity(_ enable: Bool) {
        guard !securityBusy else { notify(.warning, "⚠️ 上一操作进行中，请稍候"); return }
        securityBusy = true
        var req = adminRequest("/admin/security/enable", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            securityBusy = false
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
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
                    self.notify(.success, enable ? "✅ 鉴权已启用 — 客户端请求需携带 API Key"
                             : "✅ 鉴权已关闭（迁移宽限，密钥保留）")
                    if enable,
                       let obj = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                       let key = obj["key"] as? String, !key.isEmpty {
                        self.oneTimeKey = key
                    }
                } else {
                    self.notify(.error, "❌ 鉴权设置失败(\(code)): \(raw.prefix(100))")
                }
                self.fetchSecurityStatus()
            }
        }.resume()
    }

    /// F3: 添加服务商（name + openai_base + api_key；key 写 secrets.env，YAML 只存 ${REF}）。
    /// Task 9：completion(ok) — 失败不丢草稿（调用方按 ok 决定是否清空表单）
    func addCloudProvider(completion: ((Bool) -> Void)? = nil) {
        let name = cloudFormName.trimmingCharacters(in: .whitespaces)
        let burl = cloudFormBase.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !burl.isEmpty else {
            notify(.warning, "⚠️ 名称与 Base URL 必填")
            completion?(false)
            return
        }
        var body: [String: Any] = ["name": name, "openai_base": burl, "discovery_enabled": true]
        let aburl = cloudFormAnth.trimmingCharacters(in: .whitespaces)
        if !aburl.isEmpty { body["anthropic_base"] = aburl }   // 原生 Anthropic 直连（可选）
        let key = cloudFormKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { body["api_key"] = key }
        cloudRequest(path: "/admin/cloud/providers", method: "POST", body: body,
                     okMsg: "✅ 服务商 \(name) 已添加", failPrefix: "添加失败",
                     completion: completion)
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
                          extra: [String: Any]? = nil,
                          completion: ((Bool) -> Void)? = nil) {
        var body: [String: Any] = ["provider": provider, "action": action, "model": model]
        if let v = vision { body["supports_vision"] = v }
        if let t = tools { body["supports_tools"] = t }
        if let e = extra { for (k, val) in e { body[k] = val } }
        cloudRequest(path: "/admin/cloud/provider-models", method: "POST", body: body,
                     okMsg: "✅ \(model) · \(action) 成功", failPrefix: "\(model) \(action) 失败",
                     completion: completion)
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
    // Task 9：字段内报错（键 = 字段标题）+ 保存中状态 + 未保存修改标记
    @Published var editorFieldErrors: [String: String] = [:]
    @Published var editorSaving = false
    @Published var editorDirty = false   // 浮窗内任何草稿改动 → 关闭前确认丢弃

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
        editorFieldErrors = [:]
        editorSaving = false
        editorDirty = false
    }

    func closeCloudModelEditor() {
        cloudEditorProvider = nil
        cloudEditorSpec = nil
        editorConfirmDelete = false
        editorFieldErrors = [:]
        editorSaving = false
        editorDirty = false
    }

    /// 浮窗保存 = 一次 tag 请求落全部字段（能力 + 属性；NSNull = 清除）。
    /// Task 9 一致性：
    /// - 空白 = 清除（合法）；非空但非法 → 字段内报错、保留输入、不发请求不关闭；
    /// - 请求返回成功并应用后才关闭浮窗 — 失败/断网不关、草稿不丢；
    /// - 启用/停用不在此混发 — 云请求防抖下第二个请求会被拒，勾选仍在行内按钮。
    func saveCloudModelEditor() {
        guard let provider = cloudEditorProvider, let spec = cloudEditorSpec else { return }
        var errs: [String: String] = [:]
        var extra: [String: Any] = [:]
        func intField(_ raw: String, _ title: String, _ key: String) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { extra[key] = NSNull(); return }          // 空白 = 清除
            if let n = Int(t), n > 0 { extra[key] = n }
            else { errs[title] = "需为正整数（留空 = 清除）" }       // 非法：保留输入
        }
        func priceField(_ raw: String, _ title: String, _ key: String) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { extra[key] = NSNull(); return }
            if let d = Double(t), d >= 0 { extra[key] = d }
            else { errs[title] = "需为非负数字（¥/1M tokens）" }
        }
        intField(editorCtx, "上下文窗口（tokens）", "context_window")
        intField(editorOut, "最大输出（tokens）", "max_output_tokens")
        priceField(editorPriceIn, "输入价 ¥/1M", "price_input")
        priceField(editorPriceOut, "输出价 ¥/1M", "price_output")
        guard errs.isEmpty else {
            editorFieldErrors = errs   // 草稿原样保留，字段内可见报错
            return
        }
        editorFieldErrors = [:]
        editorSaving = true
        cloudModelAction(provider, action: "tag", model: spec.id,
                         vision: editorVision, tools: editorTools, extra: extra) { ok in
            self.editorSaving = false
            if ok { self.closeCloudModelEditor() }   // 成功才关闭
        }
    }

    /// F3: 连通性测试（用已存 key 探测全部 base）
    func cloudTestProvider(_ name: String) {
        notify(.progress, "测试 \(name) 中…")
        var req = adminRequest("/admin/cloud/provider-test", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
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
                self?.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code)
                        ? (ok ? "✅ \(name) 连通 \(detail)" : "❌ \(name) 不通：\(detail)")
                        : "❌ 测试失败(\(code))")
                self?.fetchCloud()
            }
        }.resume()
    }

    @Published var cloudBusy = false   // 云端操作防抖：进行中忽略重复触发（双击不再产生第二次 DELETE）

    func cloudRequest(path: String, method: String, body: [String: Any], okMsg: String, failPrefix: String, timeout: Double = 30, completion: ((Bool) -> Void)? = nil) {
        guard !cloudBusy else {
            notify(.warning, "⚠️ 上一操作进行中，请稍候")
            completion?(false)
            return
        }
        cloudBusy = true
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            completion?(false)
            return
        }
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !body.isEmpty { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let ok = (200..<300).contains(code)
            DispatchQueue.main.async {
                self?.cloudBusy = false
                self?.notify(ok ? .success : .error, ok ? okMsg : "❌ \(failPrefix)(\(code)): \(body.prefix(100))")
                self?.fetchCloud()
                self?.fetchPools()
                completion?(ok)
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

    // ── 监控台 v2（Task 8）──

    /// 拉取同快照报告。generation 防旧响应覆盖：网络取消不代替校验 —
    /// 响应到达时代数不匹配即丢弃；筛选切换后旧报告保留展示（带旧区间标识）。
    func fetchMonitorReport() {
        monitorGeneration += 1
        let gen = monitorGeneration
        monitorLoading = true
        var comps = URLComponents(string: "\(GW_BASE)/api/monitor-report")!
        comps.queryItems = [URLQueryItem(name: "window", value: monitorWindow),
                            URLQueryItem(name: "scope", value: monitorScope)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // 终审 I9：加载态随代数 — 旧响应不得清掉新请求的“更新中”
                guard gen == self.monitorGeneration else { return }
                self.monitorLoading = false
                guard let data,
                      let rp = try? JSONDecoder().decode(MonitorReportPayload.self, from: data) else { return }
                self.monitorReport = rp
                self.monitorReportWindow = rp.window ?? self.monitorWindow
                self.monitorReportScope = rp.scope ?? self.monitorScope
            }
        }.resume()
    }

    /// 筛选切换入口（UI Picker onChange 调用）— 立即重拉，旧数据带旧区间标识
    func selectMonitor(window: String? = nil, scope: String? = nil) {
        if let w = window, w != monitorWindow { monitorWindow = w }
        if let s = scope, s != monitorScope { monitorScope = s }
        fetchMonitorReport()
    }

    /// Task 6 运行态：冷却原因/半开探测/最近真实尝试（池卡健康的数据源）
    func fetchPoolRuntime() {
        var req = adminRequest("/admin/model-pools/runtime")
        guard attachAdminToken(&req) else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let rp = try? JSONDecoder().decode(PoolRuntimePayload.self, from: data) else { return }
            DispatchQueue.main.async { self.monitorRuntime = rp }
        }.resume()
    }

    /// 默认启动开关 — 改 models.d YAML autostart 字段（默认 false 不自动启动）
    func setAutostart(_ name: String, _ enabled: Bool) {
        var req = adminRequest("/admin/models/set-autostart", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "enabled": enabled])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code)
                        ? (enabled ? "✅ \(name) 将随网关启动" : "✅ \(name) 不再随网关启动")
                        : "❌ 设置失败(\(code)): \(body.prefix(100))")
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
        notify(.progress, "安装 \(m.name) 中…")
        var req = adminRequest("/admin/packs/install", timeoutInterval: 30)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": m.name, "type": m.type ?? "llama_cpp"])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self?.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code) ? "✅ \(m.name) 已安装（未启动 — 首请求自动唤醒）" : "❌ 安装失败(\(code)): \(body.prefix(120))")
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

    private func adminAction(_ path: String, model: String,
                             done: @escaping (FeedbackKind, String) -> Void) {
        var req = adminRequest(path, timeoutInterval: 180)
        guard attachAdminToken(&req) else {
            done(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                let ok = (200..<300).contains(code)
                done(ok ? .success : .error,
                     ok ? "✅ \(model) 完成" : "❌ \(model) 失败(\(code)): \(body.prefix(120))")
                self?.refresh(); self?.fetchModels()
            }
        }.resume()
    }

    func switchModel(_ name: String, force: Bool = false) {
        notify(.progress, force ? "已确认超卖，加载 \(name) 中…" : "切换 \(name) 中…（首次加载约 5~10s）")
        var req = adminRequest("/switch", timeoutInterval: 180)
        guard attachAdminToken(&req) else {
            notify(.error, "❌ 管理凭据未就绪 — 重启 App 重试 born 迁移")
            return
        }
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
                    self.notify(.info, "")
                    self.onMemoryInsufficient?(name, obj["message"] as? String ?? "内存不足")
                    return
                }
                self.notify((200..<300).contains(code) ? .success : .error,
                    (200..<300).contains(code) ? "✅ \(name) 完成" : "❌ \(name) 失败(\(code)): \(body.prefix(120))")
                self.refresh(); self.fetchModels()
            }
        }.resume()
    }
    func stopService(_ name: String) {
        notify(.progress, "停止 \(name) 中…")
        adminAction("/stop", model: name) { [weak self] k, msg in self?.notify(k, msg) }
    }
    func sleepModel(_ name: String) {
        notify(.progress, "\(name) 睡眠中…（唤醒约 2s）")
        adminAction("/sleep", model: name) { [weak self] k, msg in self?.notify(k, msg) }
    }
    func wakeModel(_ name: String) {
        notify(.progress, "唤醒 \(name) 中…")
        adminAction("/wake", model: name) { [weak self] k, msg in self?.notify(k, msg) }
    }

    func sendPrompt() {
        busy = true; reply = ""
        // B2/契约：试聊只认活跃 LLM，绝不回退嵌入/首个模型
        guard let target = models.first(where: { $0.active == true && $0.model_type == "llm" })?.name else {
            busy = false
            reply = "没有活跃的对话模型 — 到「本地推理」加载一个文本生成模型后再试"
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("/v1/chat/completions"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": target, "max_tokens": 300,
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": prompt]],
        ])
        // 有凭据则注入 Bearer（仅匹配档位的 loopback 推理 origin）
        if let key = currentAPIKey {
            req = (try? InferenceRequestAuthorizer.authorize(req, profile: CURRENT_PROFILE, key: key)) ?? req
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            defer { DispatchQueue.main.async { self?.busy = false } }
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    // 401/403 是鉴权问题，绝不提示安装模型
                    let hint = (code == 401 || code == 403)
                        ? "鉴权失败 — 到设置页录入有效的 API Key（或删除失效密钥）"
                        : "若模型未装，先到能力包页安装轻量对话包"
                    self?.reply = "请求失败(\(code)) \(detail.prefix(140)) — \(hint)"
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
    /// 织物条 reserve（D7 唯一公式 B = RAM − reserve，单次扣减）：
    /// env MACFABRIC_RESERVE_MB > 能力包策略 system_reserved_memory_mb > 默认 8192；
    /// env 覆盖需可见（设置页已显示策略值；env 覆盖时此处如实生效）
    var reserveMB: Int {
        if let env = ProcessInfo.processInfo.environment["MACFABRIC_RESERVE_MB"], let v = Int(env), v >= 0 {
            return v
        }
        return packPolicy?.system_reserved_memory_mb ?? 8192
    }
    var freeRatio: Double {
        guard budgetMB > 0 else { return 0 }
        return max(Double(budgetMB - usedMB - reserveMB) / Double(budgetMB), 0)
    }
    var totalRequests: Int { curve.reduce(0) { $0 + $1.requests } }
    var totalTokens: Int { curve.reduce(0) { $0 + $1.tokens } }
}

// ─── 通用元件（照设计稿 .card/.pill/.stat/.ccard）───────────────

/// 类型化操作反馈横幅（Task 10）：成功/进行中/警告/失败各有色与图标，
/// kind 来自写入时的 notify()，不解析消息文本
struct FeedbackBanner: View {
    @ObservedObject var store: GatewayStore

    private var color: Color {
        switch store.actionKind {
        case .success: return .okC
        case .progress, .info: return .accent
        case .warning: return .warnC
        case .error: return .errC
        }
    }
    private var icon: String {
        switch store.actionKind {
        case .success: return "checkmark.circle"
        case .progress: return "hourglass"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }

    var body: some View {
        if !store.actionMessage.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
                Text(store.actionMessage).font(.system(size: 12)).foregroundColor(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    store.clearActionMessage()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundColor(.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除反馈")
            }
            .padding(8).frame(maxWidth: .infinity)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

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
        .background(Color.washFaint)
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
                SideItem(label: item.1, on: tab.wrappedValue == item.0,
                         shortcut: "\(item.0 + 1)") { tab.wrappedValue = item.0 }
            }
            Text("获取").font(.system(size: 11)).foregroundColor(.faint)
                .padding(10).padding(.top, 14)
            ForEach(acquire, id: \.1) { item in
                SideItem(label: item.1, on: tab.wrappedValue == item.0,
                         shortcut: "\(item.0 + 1)") { tab.wrappedValue = item.0 }
            }
            Spacer()
            SideItem(label: "设置", on: tab.wrappedValue == 7, shortcut: "8") { tab.wrappedValue = 7 }
                .padding(.bottom, 10)
        }
        .frame(width: 172)
        .padding(.horizontal, 8)
        .background(Color.washFaint)
    }
}

struct SideItem: View {
    let label: String
    let on: Bool
    var placeholder = false
    var shortcut: String? = nil   // ⌘1–8 页签直达（Task 10 键盘可达）
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
        .keyboardShortcut(shortcut.map { KeyEquivalent(Character($0)) } ?? KeyEquivalent.delete,
                          modifiers: shortcut == nil ? .command : .command)
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
        segs.append(WeaveSeg(color: Color.wash, ratio: store.freeRatio, name: "空闲",
                     gb: String(format: "%.1f", Double(max(store.budgetMB - store.usedMB - store.reserveMB, 0)) / 1024)))
        segs.append(WeaveSeg(color: Color.washStrong, ratio: Double(store.reserveMB) / Double(max(store.budgetMB, 1)), name: "系统保留", gb: "8.0"))
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
    // B3 样稿契约：本地 + 云端同页单张统一表（原生 Table，类型/来源成列）；
    // 模型池是独立服务概念（表格下方脚注卡片）；云端行原样保留上游 ID；
    // 每模型按类型给出真实端点示例，密钥只用占位符。

    var body: some View {
        let allRows = localRows + cloudRows
        let sel = allRows.first(where: { $0.id == store.hubSelectedID })
        let w = store.contentWidths["hub"] ?? 900
        HStack(spacing: 0) {
            // 原生布局：表格不套 ScrollView（Table 在 ScrollView 里高度塌缩为 0），
            // 表格占满剩余空间自行滚动；接入条固定顶部、模型池脚注固定底部
            VStack(alignment: .leading, spacing: 14) {
                // 接入条（唯一地址 + 真实鉴权状态）
                Card {
                    HStack(spacing: 10) {
                        Chip("接入地址")
                        Text(GW_BASE).font(.system(size: 12, design: .monospaced)).foregroundColor(.ink)
                        Chip(store.authPresentation.text)   // B2：真实状态 — 未知 ≠ 未启用
                        Spacer()
                        CopyButton("复制 Base URL", text: GW_BASE, small: true)
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                }
                Group {
                    if allRows.isEmpty {
                        if store.gatewayUp {
                            Text("暂无模型 — 本地模型到「本地推理」加载，云端模型到「云端接入」启用")
                                .font(.system(size: 12)).foregroundColor(.faint)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .padding(.top, 24)
                        } else {
                            VStack(spacing: 6) {
                                Text("网关离线").font(.system(size: 13, weight: .medium)).foregroundColor(.dim)
                                Text("已加载的模型列表会在网关启动后自动恢复").font(.system(size: 12)).foregroundColor(.faint)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 24)
                        }
                    } else {
                        // 单张统一表（原生 Table）：本地 + 云端同页，类型/来源成列
                        ModelTable(page: .hub, rows: allRows,
                                   selectedID: store.hubSelectedID,
                                   onSelect: { store.hubSelectedID = $0.isEmpty ? nil : $0 },
                                   availableWidth: w)
                            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    }
                }
                // 宽度测在表格本体上（不含页面 padding），断点才与真实列宽一致
                .background(WidthReader(key: "hub", store: store))
                // 模型池：独立路由服务（轻量脚注，不与模型表混排）
                poolsFootnote
            }
            .padding(16)
            // 详情：右侧并行栏（样稿契约），不混入滚动流
            if let sel {
                Divider().overlay(Color.lineC)
                ModelDetails(row: sel,
                             fields: hubDetailFields(sel),
                             onClose: { store.hubSelectedID = nil })
                    .frame(width: DS.Table.detailWidth)
            }
        }
    }

    // 本地模型行：调用地始终是网关公开调用 ID（现阶段 = instance name）
    private var localRows: [ModelTableRow] {
        store.models.map { m in
            ModelTableRow(
                id: m.name,
                title: inferenceDisplayName(m),
                type: PrimaryType.from(raw: m.model_type ?? m.type),
                runState: store.snapshot?.status.sleep_states?[m.name] != nil
                    ? .sleeping : (m.active == true ? .available : .notLoaded),
                sourceText: "本地模型",
                target: ModelActionTarget(instanceID: m.name, apiModelID: m.name,
                                          packID: m.managed_by_pack?.pack_id),
                actions: [ModelTableAction(label: "接入配置") { store.hubSelectedID = m.name }])
        }
    }

    /// 官方真名：能力包目录 display_name 优先；"capability pack …" 描述串不算名字
    private func inferenceDisplayName(_ m: ModelItem) -> String? {
        if let pid = m.managed_by_pack?.pack_id,
           let entry = store.packCatalog?.packs.first(where: { $0.pack_id == pid }),
           !entry.display_name.isEmpty {
            return entry.display_name
        }
        if let d = m.description, !d.isEmpty, !d.hasPrefix("capability pack") {
            return d
        }
        return nil
    }

    // 云端模型行：上游 ID 原样保留作标题（裁决 2026-11-16）。
    // 类型按服务事实归类：发现载荷均为 openai/anthropic chat 可用 → 文本生成；
    // 看图三态统一走 VisionPresentation（supports_vision==true 才出标签，nil/false 均不出）。
    private var cloudRows: [ModelTableRow] {
        (store.cloud?.models ?? []).map { cm in
            let caps: [CapabilityTag] = VisionPresentation.showsTag(supportsVision: cm.capabilities?.supports_vision)
                ? [CapabilityTag(id: "vision", label: "看图")] : []
            return ModelTableRow(
                id: "cloud|\(cm.id)",
                title: cm.id,
                type: .llm,
                capabilities: caps,
                subtitle: caps.isEmpty ? nil : caps.map(\.label).joined(separator: " / "),
                runState: .available,
                sourceText: "云端 · \(cm.provider ?? "未知来源")",
                target: ModelActionTarget(instanceID: cm.id, apiModelID: cm.id, packID: nil),
                actions: [ModelTableAction(label: "接入配置") { store.hubSelectedID = "cloud|\(cm.id)" }])
        }
    }

    // 模型池轻量脚注（样稿 footnote 语义）：一行说明 + 池速览 + 管理入口，无卡片底
    private var poolsFootnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.lineC)
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundColor(DS.accent)
                Text("模型池").font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                Text("独立路由服务 · 同类能力聚合，一处调整对多 Agent 生效")
                    .font(.system(size: 11)).foregroundColor(.faint)
                let pools = store.pools?.pools ?? [:]
                ForEach(pools.keys.sorted(), id: \.self) { name in
                    HStack(spacing: 3) {
                        Circle().fill(pools[name]?.enabled == true ? DS.okC : DS.faint).frame(width: 6, height: 6)
                        Text(name).font(DS.mono(11)).foregroundColor(.dim)
                        Text("\((pools[name]?.candidates ?? []).count)")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.faint)
                    }
                }
                Spacer()
                SmallBtn("管理模型池") { store.tab = 3 }
            }
        }
    }

    private func hubDetailFields(_ row: ModelTableRow) -> [ModelDetailField] {
        var f: [ModelDetailField] = []
        f.append(ModelDetailField("Base URL", "\(GW_BASE)/v1", mono: true, copyable: true))
        f.append(ModelDetailField("来源", row.sourceText ?? "本地模型", mono: false, copyable: false))
        // 看图三态详情（spec 2026-11-17 红线 2）：仅 supports_vision=false 如实标注"不支持"；
        // 未声明(nil)不提、已支持(true)已有能力标签不重复
        if let cm = (store.cloud?.models ?? []).first(where: { "cloud|\($0.id)" == row.id }),
           let note = VisionPresentation.detailText(supportsVision: cm.capabilities?.supports_vision) {
            f.append(ModelDetailField("看图", note, mono: false, copyable: false))
        }
        if let ep = APIExamples.endpoint(for: row.type) {
            f.append(ModelDetailField("端点", ep, mono: true, copyable: false))
        }
        // 按类型即拷配置（密钥只用占位符；未知类型无端点 → 不生成伪有效示例）
        if let curl = APIExamples.make(modelID: row.target.apiModelID, type: row.type,
                                       baseURL: GW_BASE, format: .curl) {
            f.append(ModelDetailField("cURL", curl, mono: true, copyable: true, multiline: true))
        }
        if let json = APIExamples.make(modelID: row.target.apiModelID, type: row.type,
                                       baseURL: GW_BASE, format: .json) {
            f.append(ModelDetailField("JSON", json, mono: true, copyable: true, multiline: true))
        }
        if let env = APIExamples.make(modelID: row.target.apiModelID, type: row.type,
                                      baseURL: GW_BASE, format: .env) {
            f.append(ModelDetailField("环境变量", env, mono: true, copyable: true, multiline: true))
        }
        return f
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
            .background(color.map { $0.opacity(0.10) } ?? Color.glass, in: Capsule())
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
        .background(Color.wash, in: RoundedRectangle(cornerRadius: 6))
        .foregroundColor(.ink)
    }
}

// ─── 本地推理页（.mrow 一行一模型 + 底部试聊）────────────────────

struct InferenceView: View {
    @ObservedObject var store: GatewayStore
    // B3：共享表格 + 详情栏。选中按 instanceID 保持（存 store，规避 CLT 无 @State 宏）；
    // 行刷新后选中项已不存在则视为无选中（选择保持语义由 SelectionKeeper 契约测试钉住）。
    private var selection: String? {
        get { store.inferenceSelectedID }
        nonmutating set { store.inferenceSelectedID = newValue }
    }

    var body: some View {
        let rows = store.models.map { m in
            inferenceRow(store: store, m: m,
                         sleeping: store.snapshot?.status.sleep_states?[m.name] != nil)
        }
        let sel = rows.contains(where: { $0.id == selection }) ? selection : nil
        let w = store.contentWidths["inference"] ?? 900
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("网关未返回模型 — 检查网关状态或到能力包页安装")
                            .font(.system(size: 12)).foregroundColor(.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ModelTable(page: .localInference, rows: rows,
                                   selectedID: sel,
                                   onSelect: { store.inferenceSelectedID = $0 },
                                   availableWidth: w)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .background(WidthReader(key: "inference", store: store))
                if let sel, let row = rows.first(where: { $0.id == sel }) {
                    Divider().overlay(Color.lineC)
                    ModelDetails(row: row,
                                 fields: detailFields(for: row),
                                 autostart: Binding(
                                    get: { store.models.first(where: { $0.name == sel })?.autostart ?? false },
                                    set: { store.setAutostart(sel, $0) }),
                                 onClose: { store.inferenceSelectedID = nil })
                        .frame(width: DS.Table.detailWidth)
                        .accessibilityIdentifier("model-details:\(sel)")
                }
            }
            Divider().overlay(Color.lineC)
            ChatStrip(store: store)
        }
    }

    private func inferenceRow(store: GatewayStore, m: ModelItem, sleeping: Bool) -> ModelTableRow {
        let target = ModelActionTarget(instanceID: m.name, apiModelID: m.name,
                                       packID: m.managed_by_pack?.pack_id)
        var actions: [ModelTableAction] = []
        if sleeping {
            actions.append(ModelTableAction(label: "唤醒", primary: true) { store.wakeModel(m.name) })
        } else if m.active == true {
            actions.append(ModelTableAction(label: "睡眠", primary: false) { store.sleepModel(m.name) })
            actions.append(ModelTableAction(label: "停止", primary: false) { store.stopService(m.name) })
        } else {
            actions.append(ModelTableAction(label: "加载", primary: true) { store.switchModel(m.name) })
        }
        let runState: RunState = sleeping ? .sleeping : (m.active == true ? .available : .notLoaded)
        return ModelTableRow(
            id: m.name,
            title: displayName(for: m),
            type: PrimaryType.from(raw: m.model_type ?? m.type),
            runState: runState,
            memoryText: MemoryMath.baselineText(mb: m.peak_vram_mb),   // nil → 未知，不是 0
            target: target,
            actions: actions)
    }

    /// 官方真名解析：能力包目录 display_name 优先（真实资料源）；
    /// 网关 description 若是 "capability pack …" 描述串则视为无名字，诚实回退。
    private func displayName(for m: ModelItem) -> String? {
        if let pid = m.managed_by_pack?.pack_id,
           let entry = store.packCatalog?.packs.first(where: { $0.pack_id == pid }),
           !entry.display_name.isEmpty {
            return entry.display_name
        }
        if let d = m.description, !d.isEmpty, !d.hasPrefix("capability pack") {
            return d
        }
        return nil
    }

    private func detailFields(for row: ModelTableRow) -> [ModelDetailField] {
        guard let m = store.models.first(where: { $0.name == row.id }) else { return [] }
        var f: [ModelDetailField] = []
        f.append(ModelDetailField("引擎", m.type == "llama_cpp" ? "llama.cpp" : (m.type ?? "未知")))
        let port = store.snapshot?.status.services_info?[m.name]?.port.map(String.init) ?? "未知"
        f.append(ModelDetailField("端口", port, mono: true, copyable: false))
        f.append(ModelDetailField("装载", m.ledgerMode == "resident" ? "常驻" : "按需", mono: false, copyable: false))
        if let pid = m.managed_by_pack?.pack_id {
            f.append(ModelDetailField("来源", "能力包 · \(pid)", mono: false, copyable: false))
        }
        return f
    }
}

/// 设计稿 .mrow：一行一模型 — 状态、装载模式、内存账、三个动作
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
            .background(primary ? Color.accent : Color.wash,
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
      -H "Authorization: Bearer $MACFABRIC_API_KEY" -H "Content-Type: application/json" \\
      -d '{"model":"fabric-fast","messages":[{"role":"user","content":"你好"}]}'
    """

    static func copyUsageSnippet() {
        let text = """
        # MacFabric 池调用（OpenAI 方言；Anthropic 方言把 URL 换成 http://127.0.0.1:\(GW_PORT) 即可）
        export OPENAI_BASE_URL=http://127.0.0.1:\(GW_PORT)/v1
        export OPENAI_API_KEY=$MACFABRIC_API_KEY   # 设置页「API Key 鉴权」新建后填入真实 key
        # model 填池名：fabric-fast · fabric-small · fabric-premium（按池内优先级自动调度）
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
                FeedbackBanner(store: store)
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
                                     "直接填池名：fabric-fast · fabric-small · fabric-premium — 网关按池内优先级自动选候选，失败自动换下一个，无需改客户端")
                            // B2：真实状态派生 — 网关不可达/未取到 = 状态未知，绝不说“未开启”
                            let keyGuide: String = {
                                switch store.authPresentation {
                                case .enabledAll:
                                    return "鉴权已启用 · 全部请求 — 用设置页「API Key 鉴权 → ＋ 新建密钥」生成的 key，请求头 Authorization: Bearer <key>"
                                case .enabledPools:
                                    return "仅模型池请求需要 key — 设置页「API Key 鉴权」可录入"
                                case .disabled:
                                    return "鉴权未开启 — 本机调用免 key；开启鉴权后在设置页新建"
                                case .unknown:
                                    return "鉴权状态未知 — 网关不可达或未返回状态；本机调用可先免 key 试，失败再看设置页"
                                }
                            }()
                            guideRow("③ API Key", keyGuide)
                            Text("示例（终端可直接粘贴）")
                                .font(.system(size: 10.5)).foregroundColor(.dim)
                            Text(Self.usageSnippet)
                                .font(.system(size: 10.5, design: .monospaced)).foregroundColor(.dim)
                                .lineLimit(4).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.wash, in: RoundedRectangle(cornerRadius: 6))
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
                    Text("fabric-\(name)").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
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
                        // 换模型：本机（llm/vl，裁决 2026-11-16）+ 云端可作候选
                        Menu("换") {
                            Section("本机") {
                                ForEach(store.models.filter {
                                    $0.model_type == "llm" || $0.model_type == "vl"
                                }, id: \.name) { m in
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
                        // Task 10：次要操作收进 ⋯ 菜单（始终可发现，不 hover 隐藏）；
                        // 排序入口（↑↓/拖拽）保留在行面
                        Menu {
                            Button("移除候选…") {
                                store.confirm("从池 fabric-\(name) 移除候选 \(c.target ?? c.id)？") {
                                    store.removePoolCandidate(pool: name, candidateId: c.id)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 12)).foregroundColor(.dim)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
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
                    .opacity(store.poolDragging == "\(name)|\(c.id)" ? 0.4 : 1)
                    .onDrag {
                        store.poolDragging = "\(name)|\(c.id)"
                        return NSItemProvider(object: "\(name)|\(c.id)" as NSString)
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
                            // 裁决 2026-11-16：池备选只列 chat 可用模型（llm/vl）—
                            // embedding/tts/asr 进池永远不可用，模型越多列表越长
                            ForEach(store.models.filter {
                                $0.model_type == "llm" || $0.model_type == "vl"
                            }, id: \.name) { m in
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
                // 高级设置（Task 6 参数接入 — Task 9 一致性）
                poolAdvanced
            }
            .padding(12)
            .onDrop(of: ["public.utf8-plain-text"], delegate: PoolCancelDropDelegate(store: store))
        }
    }

    // ── 高级设置：max_attempts / deadline_ms（Task 6 范围 1–10 / 1000–300000）──
    @ViewBuilder private var poolAdvanced: some View {
        Divider().padding(.vertical, 4)
        HStack(spacing: 8) {
            Button {
                store.togglePoolAdvanced(name, def: def)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.poolAdvExpanded == name ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.faint)
                    Text("高级设置").font(.system(size: 11)).foregroundColor(.dim)
                }
            }.buttonStyle(.plain)
            Text("重试上限 \(def.max_attempts.map(String.init) ?? "2（默认）") 次 · 截止预算 \(def.deadline_ms.map(String.init) ?? "60000（默认）")ms")
                .font(.system(size: 10.5)).foregroundColor(.faint)
            Spacer()
        }
        if store.poolAdvExpanded == name {
            VStack(alignment: .leading, spacing: 6) {
                Text("重试也消耗尝试次数；截止预算（deadline）包含排队与回退时间。留空 = 不修改。")
                    .font(.system(size: 10.5)).foregroundColor(.faint)
                HStack(spacing: 10) {
                    advField("max_attempts（1–10 次）", store.poolAdvAttempts,
                             set: { store.poolAdvAttempts = $0 })
                        .frame(maxWidth: 200)
                    advField("deadline_ms（1000–300000 毫秒）", store.poolAdvDeadline,
                             set: { store.poolAdvDeadline = $0 })
                        .frame(maxWidth: 240)
                }
                if !store.poolAdvError.isEmpty {
                    Text(store.poolAdvError).font(.system(size: 10.5)).foregroundColor(.warnC)
                }
                HStack {
                    SmallBtn("保存参数", primary: true) { store.savePoolAdvanced(name) }
                    SmallBtn("恢复默认") { store.resetPoolAdvanced(name) }
                }
            }
            .padding(10)
            .background(Color.wash, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func advField(_ title: String, _ text: String, set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.faint)
            TextField("留空 = 不修改", text: Binding(get: { text }, set: set))
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
        }
    }
}

// 池候选行拖拽落点 — 命中即把拖拽候选移到本行位置（priority 全量重建，CAS 回写）。
// Task 9：drop 身份是 "pool|candidate"，仅同池放行 — 禁止跨池误操作
struct PoolRowDropDelegate: DropDelegate {
    var store: GatewayStore
    let pool: String
    let targetId: String

    /// "pool|id" → (pool, id)；旧格式（纯 id）解析失败返回 nil
    private func parse(_ s: String) -> (String, String)? {
        let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
    func validateDrop(info: DropInfo) -> Bool {
        guard let dragging = store.poolDragging,
              let (srcPool, srcId) = parse(dragging),
              srcPool == pool, srcId != targetId else { return false }
        return true
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) {}
    func performDrop(info: DropInfo) -> Bool {
        defer { store.poolDragging = nil }   // 取消/完成都清理高亮
        guard let dragging = store.poolDragging,
              let (srcPool, dragged) = parse(dragging),
              srcPool == pool else { return false }   // 跨池拒绝，不动其他池配置
        guard dragged != targetId else { return true }
        store.moveCandidate(pool: pool, dragged: dragged, target: targetId)
        return true
    }
}

/// 拖拽取消落点：候选链容器空白处接住放下的拖拽 — 清理高亮、不产生任何改动
struct PoolCancelDropDelegate: DropDelegate {
    var store: GatewayStore
    func validateDrop(info: DropInfo) -> Bool { store.poolDragging != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .cancel) }
    func performDrop(info: DropInfo) -> Bool {
        store.poolDragging = nil
        return true
    }
}

struct MonitorView: View {
    @ObservedObject var store: GatewayStore

    static let windowChoices = [("1h", "近1小时"), ("24h", "近24小时"), ("7d", "近7天"), ("30d", "近30天")]
    static let scopeChoices = [("all", "全部"), ("local", "本机"), ("cloud", "云端")]
    static let windowLabels = ["1h": "近1小时", "24h": "近24小时", "7d": "近7天", "30d": "近30天"]
    static let errorLabels = ["upstream_5xx": "上游 5xx", "rate_limited": "限流 429",
                              "auth": "鉴权失败", "upstream_4xx": "上游 4xx",
                              "no_upstream": "无可用上游", "other": "其他"]

    /// 展示中报告落后于当前选择（旧数据保留展示，不套新标签 — QA 场景 3）
    var showingStale: Bool {
        store.monitorLoading &&
        (store.monitorReportWindow != store.monitorWindow ||
         store.monitorReportScope != store.monitorScope)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeader
            Rectangle().fill(Color.lineC).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let rp = store.monitorReport { reportBody(rp) }
                    else if store.monitorLoading {
                        Card {
                            Text("加载报告…").font(.system(size: 12)).foregroundColor(.faint)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    } else {
                        Card {
                            Text(store.gatewayUp ? "暂无数据 — 发起一次对话后这里会出现统计"
                                                 : "网关离线 — 启动后此处显示监控统计")
                                .font(.system(size: 12)).foregroundColor(.faint)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                }.padding(18)
            }
        }
        // 显示时立即拉取（终审 I9：重进页面无条件刷新，旧报告只在等待
        // 期间展示）；同查询单飞在网关侧短 TTL 缓存兜底，子视图不重复发请求
        .onAppear {
            store.fetchMonitorReport()
            store.fetchPoolRuntime()
        }
    }

    /// 筛选控件组（终审 I10）：宽窄两种排布共用
    @ViewBuilder private var monitorFilters: some View {
        Picker("范围", selection: Binding(
            get: { store.monitorWindow },
            set: { store.selectMonitor(window: $0) })) {
            ForEach(Self.windowChoices, id: \.0) { w in Text(w.1).tag(w.0) }
        }.pickerStyle(.segmented).frame(width: 330).fixedSize()
        Picker("来源", selection: Binding(
            get: { store.monitorScope },
            set: { store.selectMonitor(scope: $0) })) {
            ForEach(Self.scopeChoices, id: \.0) { s in Text(s.1).tag(s.0) }
        }.pickerStyle(.segmented).fixedSize()
        if showingStale {
            Text("切换中 · 显示\(Self.windowLabels[store.monitorReportWindow] ?? store.monitorReportWindow)旧数据")
                .font(.system(size: 11)).foregroundColor(.dim)
        } else if store.monitorLoading {
            Text("更新中…").font(.system(size: 11)).foregroundColor(.faint)
        }
    }

    /// 窄窗口不裁切（终审 I10 / QA M 项）：宽度足够单行排布，否则两行堆叠
    private var filterHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                monitorFilters
                Spacer()
                SmallBtn("刷新") { store.fetchMonitorReport(); store.fetchPoolRuntime() }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { monitorFilters }
                HStack {
                    Spacer()
                    SmallBtn("刷新") { store.fetchMonitorReport(); store.fetchPoolRuntime() }
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    @ViewBuilder private func reportBody(_ rp: MonitorReportPayload) -> some View {
        if let t = rp.totals {
            HStack(spacing: 12) {
                StatCard(v: fmtInt(t.requests), k: "请求")
                StatCard(v: rateText(t.success_rate), k: "成功率")
                StatCard(v: fmtInt(t.tokens_in), k: "输入 tokens")
                StatCard(v: fmtInt(t.tokens_out), k: "输出 tokens")
                StatCard(v: costText(t), k: "费用估算")
            }
        }
        // 用量趋势：仅总量柱状 — 不默认展示全部模型折线（模型详情看表+详情卡）
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("请求趋势（\(Self.windowLabels[rp.window ?? ""] ?? rp.window ?? "")）")
                        .font(.system(size: 12.5)).foregroundColor(.dim)
                    Spacer()
                    if rp.coverage?.truncated == true {
                        Text("数据截断").font(.system(size: 10.5)).foregroundColor(.dim)
                    }
                }
                let buckets = (rp.series ?? []).sorted { ($0.bucket_start ?? 0) < ($1.bucket_start ?? 0) }
                if buckets.isEmpty || buckets.allSatisfy({ ($0.requests ?? 0) == 0 }) {
                    Text("暂无调用 — 发起一次对话后出现柱状图")
                        .foregroundColor(.faint).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart(buckets, id: \.bucket_start) { b in
                        BarMark(
                            x: .value("时间", Date(timeIntervalSince1970: b.bucket_start ?? 0)),
                            y: .value("请求", b.requests ?? 0)
                        )
                        .foregroundStyle(Color.accent.opacity(0.75))
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 140)
                }
            }.padding(14)
        }
        modelTableCard(rp)
        poolStatsCard(rp)
        errorCard(rp)
    }

    // ── 模型表 + 选中模型详情 ──
    @ViewBuilder private func modelTableCard(_ rp: MonitorReportPayload) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("模型").font(.system(size: 12.5)).foregroundColor(.dim)
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            tableHead("模型").frame(width: 200, alignment: .leading)
                            tableHead("来源").frame(width: 70)
                            tableHead("请求").frame(width: 55)
                            tableHead("成功率").frame(width: 60)
                            tableHead("tokens").frame(width: 100)
                            tableHead("TTFT p50").frame(width: 80)
                            tableHead("TTFT p95").frame(width: 80)
                            Spacer()
                        }
                        ForEach(rp.models ?? []) { m in
                            Button {
                                store.monitorSelectedModel =
                                    store.monitorSelectedModel == m.id ? nil : m.id
                            } label: {
                                HStack(spacing: 0) {
                                    HStack(spacing: 6) {
                                        Circle().fill(m.location == "cloud" ? Color.thLlm : Color.okC)
                                            .frame(width: 7, height: 7)
                                        Text(modelDisplay(m)).font(.system(size: 12)).foregroundColor(.ink).lineLimit(1)
                                            .truncationMode(.middle)
                                    }.frame(width: 200, alignment: .leading)
                                    Text(scopeText(m)).font(.system(size: 11)).foregroundColor(.dim).frame(width: 70)
                                    Text(fmtInt(m.requests)).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.ink).frame(width: 55)
                                    Text(rateText(m.success_rate)).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 60)
                                    Text("\(fmtInt(m.tokens_in))/\(fmtInt(m.tokens_out))").font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 100)
                                    Text(ttftText(m.p50_ttft_ms, m.ttft_samples)).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 80)
                                    Text(ttftText(m.p95_ttft_ms, m.ttft_samples)).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim).frame(width: 80)
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .background(store.monitorSelectedModel == m.id ? Color.accent.opacity(0.08) : Color.clear)
                            Rectangle().fill(Color.lineC).frame(height: 1)
                        }
                        if (rp.models ?? []).isEmpty {
                            Text("暂无调用数据").font(.system(size: 11.5)).foregroundColor(.faint)
                        }
                    }
                }
                if let sel = selectedRow(rp) { modelDetail(sel) }
            }.padding(14)
        }
    }

    /// 模型名完整可查看：详情卡原文展示（可选中复制），表格行只做省略
    private func selectedRow(_ rp: MonitorReportPayload) -> MonitorModelRow? {
        guard let id = store.monitorSelectedModel else { return nil }
        return (rp.models ?? []).first { $0.id == id }
    }

    private func modelDetail(_ m: MonitorModelRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模型详情").font(.system(size: 11)).foregroundColor(.faint)
                Spacer()
            }
            Text(modelDisplay(m))
                .font(.system(size: 12.5, design: .monospaced)).foregroundColor(.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                perfCell("TTFT p50", ttftText(m.p50_ttft_ms, m.ttft_samples))
                perfCell("TTFT p95", ttftText(m.p95_ttft_ms, m.ttft_samples))
                perfCell("端到端 p50", durText(m.p50_duration_ms, m.duration_samples))
                perfCell("端到端 p95", durText(m.p95_duration_ms, m.duration_samples))
            }
            Text("TTFT 样本 \(m.ttft_samples ?? 0) · 时长样本 \(m.duration_samples ?? 0) · 成功 \(fmtInt(m.success))/\(fmtInt(m.requests))")
                .font(.system(size: 10.5)).foregroundColor(.faint)
        }
        .padding(10)
        .background(Color.wash, in: RoundedRectangle(cornerRadius: 8))
    }

    private func perfCell(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10)).foregroundColor(.faint)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundColor(.ink)
        }
    }

    // ── 池统计（轻量摘要；详情展开回退/冷却 — 健康来自 Task 6 runtime）──
    @ViewBuilder private func poolStatsCard(_ rp: MonitorReportPayload) -> some View {
        let pools = (rp.pools ?? []).sorted { ($0.requests ?? 0) > ($1.requests ?? 0) }
        if !pools.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型池（\(Self.windowLabels[rp.window ?? ""] ?? "")）")
                        .font(.system(size: 12.5)).foregroundColor(.dim)
                    ForEach(pools, id: \.pool) { p in poolRow(p) }
                }.padding(14)
            }
        }
    }

    @ViewBuilder private func poolRow(_ p: MonitorPoolRow) -> some View {
        let name = p.pool ?? "—"
        let reqs = p.requests ?? 0
        let rate: Double? = reqs > 0 ? Double(p.success ?? 0) / Double(reqs) : nil
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.monitorPoolExpanded = store.monitorPoolExpanded == name ? nil : name
            } label: {
                HStack(spacing: 12) {
                    Text("fabric-\(name)").font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                    Text("\(fmtInt(reqs)) 请求").font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim)
                    Text("成功率 \(rateText(rate))")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundColor(.dim)
                    if let top = topTarget(p) {
                        Text("最终承接 \(top)").font(.system(size: 11)).foregroundColor(.dim).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: store.monitorPoolExpanded == name ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9)).foregroundColor(.faint)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if store.monitorPoolExpanded == name {
                VStack(alignment: .leading, spacing: 4) {
                    Text("尝试 \(p.attempt_count ?? 0) · 重试(同目标) \(p.retry_count ?? 0) · 回退(换目标) \(p.fallback_count ?? 0) · 摘要覆盖 \(Int((p.summary_coverage ?? 0) * 100))%")
                        .font(.system(size: 11)).foregroundColor(.dim)
                    // 候选健康：Task 6 runtime — 冷却原因/半开探测/最近真实尝试
                    let cands = store.monitorRuntime?.pools?[name]?.candidates ?? []
                    if cands.isEmpty {
                        Text("候选运行态不可用（池未配置或网关离线）")
                            .font(.system(size: 11)).foregroundColor(.faint)
                    } else {
                        ForEach(cands, id: \.id) { c in
                            HStack(spacing: 8) {
                                Circle().fill(c.active == true ? Color.okC : Color.faint.opacity(0.5))
                                    .frame(width: 7, height: 7)
                                Text(c.target ?? c.id ?? "—").font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.ink).lineLimit(1).truncationMode(.middle)
                                if let cool = c.cooling {
                                    Text(cool.probing == true
                                         ? "半开探测中"
                                         : "冷却 \(Int(cool.remaining_s ?? 0))s · \(cool.reason ?? "")")
                                        .font(.system(size: 10.5)).foregroundColor(.dim)
                                }
                                if let last = c.last_attempt {
                                    Text("最近尝试 \(last.ok == true ? "✓" : "✗")\(last.status.map { " \($0)" } ?? "") · \(Int(last.age_s ?? 0))s 前")
                                        .font(.system(size: 10.5)).foregroundColor(.faint)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.wash, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 2)
    }

    private func topTarget(_ p: MonitorPoolRow) -> String? {
        let ft = p.final_targets ?? [:]
        return ft.max { $0.value < $1.value }?.key
    }

    // ── 错误分类（脱敏：仅类别 + 计数）──
    @ViewBuilder private func errorCard(_ rp: MonitorReportPayload) -> some View {
        let errs = (rp.errors ?? []).filter { ($0.count ?? 0) > 0 }
        if !errs.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("错误分类").font(.system(size: 12.5)).foregroundColor(.dim)
                    HStack(spacing: 10) {
                        ForEach(errs, id: \.id) { e in
                            let cls = e.class ?? "other"
                            HStack(spacing: 4) {
                                Text(Self.errorLabels[cls] ?? cls)
                                    .font(.system(size: 11)).foregroundColor(.dim)
                                Text("\(fmtInt(e.count))")
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundColor(.ink)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.lineC.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.padding(14)
            }
        }
    }

    // ── 格式化 ──
    private func tableHead(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5)).foregroundColor(.faint)
    }
    private func modelDisplay(_ m: MonitorModelRow) -> String {
        let name = m.model ?? "unknown"
        if m.location == "cloud", let p = m.provider, !p.isEmpty { return "\(p)/\(name)" }
        return name
    }
    private func scopeText(_ m: MonitorModelRow) -> String {
        switch m.location {
        case "local": return "本机"
        case "cloud": return "云端"
        default: return "未归属"
        }
    }
    private func fmtInt(_ v: Int?) -> String {
        guard let v else { return "—" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    private func rateText(_ r: Double?) -> String {
        guard let r else { return "—" }
        return "\(Int((r * 100).rounded()))%"
    }
    /// 缺 TTFT（样本 0）= unknown 显示 "—"，不是 0ms
    private func ttftText(_ v: Double?, _ samples: Int?) -> String {
        guard let v, (samples ?? 0) > 0 else { return "—" }
        return String(format: "%.0fms", v)
    }
    private func durText(_ v: Double?, _ samples: Int?) -> String {
        guard let v, (samples ?? 0) > 0 else { return "—" }
        return v >= 1000 ? String(format: "%.1fs", v / 1000) : String(format: "%.0fms", v)
    }
    private func costText(_ t: MonitorTotals) -> String {
        // 缺价格配置 = unknown（"未配价"），不冒充 ¥0.00；单位与价格配置一致（¥）
        guard let v = t.cost_estimate else { return "未配价" }
        return String(format: "¥%.2f", v)
    }
}

// ─── 主窗口：侧栏 + 内容区 ─────────────────────────────────────

struct MainWindowView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(tab: Binding(get: { store.tab }, set: {
                store.tab = $0
                store.cancelPoolDrag()   // 离开池页清拖拽高亮，不残留
            }))
            Rectangle().fill(Color.lineC).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.panel)
        }
        .background(Color.panel)
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

/// 能力包：产品主入口 —— 装的是能力不是模型文件（PK4 v2：Catalog 驱动，
/// App 只提交 pack_id，URL/hash 由后端提供 — Catalog-only 裁决 spec §6.1）
func packStageLabel(_ s: String?) -> String {
    switch s {
    case "preflight": return "预检中…"
    case "staging": return "准备中…"
    case "downloading": return "下载中…"
    case "verifying": return "校验中…"
    case "preparing_runtime": return "准备运行时…"
    case "writing_config": return "写入配置…"
    case "isolated_healthcheck": return "健康检查中…"
    case "gateway_reload": return "重载中…"
    case "installed": return "已安装"
    default: return s == nil || s!.isEmpty ? "" : s!
    }
}

struct PacksView: View {
    @ObservedObject var store: GatewayStore
    // B3：能力分类分区（用户裁决）+ 共享目录表（行键 packID:variant；
    // 验证列诚实显示“待验证”——risk_level 不是验证记录；包 ID/变体/路径进详情）

    private static let capOrder = ["llm", "vl", "embedding", "rerank", "tts", "asr", "ocr", "aigc"]
    private static let capSection: [String: String] = [
        "llm": "对话（LLM）", "vl": "看图（VL）", "embedding": "嵌入 / 检索",
        "rerank": "重排", "tts": "语音合成", "asr": "语音转写",
        "ocr": "文字识别", "aigc": "生图",
    ]
    private var groups: [(cap: String, entries: [PackCatalogEntry])] {
        let packs = store.packCatalog?.packs ?? []
        var byCap: [String: [PackCatalogEntry]] = [:]
        for p in packs { byCap[p.capability, default: []].append(p) }
        let known = Self.capOrder.compactMap { cap -> (String, [PackCatalogEntry])? in
            byCap[cap].map { (cap, $0) }
        }
        let rest = byCap.filter { Self.capSection[$0.key] == nil }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return (known + rest).map { (cap: $0.0, entries: $0.1) }
    }

    var body: some View {
        let allRows = groups.flatMap { packRows($0.entries) }
        let shown = allRows.filter { store.packTypeFilter.isEmpty || $0.type.displayName == store.packTypeFilter }
        let presentTypes = allRows.map(\.type.displayName)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let sel = allRows.first(where: { $0.id == store.packSelectedID })
        let w = store.contentWidths["packs"] ?? 900
        HStack(spacing: 0) {
            // 原生布局：表格不套 ScrollView（Table 在 ScrollView 里高度塌缩为 0）
            VStack(alignment: .leading, spacing: 14) {
                FeedbackBanner(store: store)
                // 类型筛选（原生分段控件；空目录不显示）
                if !presentTypes.isEmpty {
                    Picker("类型", selection: $store.packTypeFilter) {
                        Text("全部").tag("")
                        ForEach(presentTypes.keys.sorted(), id: \.self) { t in
                            Text("\(t) (\(presentTypes[t] ?? 0))").tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                }
                Group {
                    if allRows.isEmpty {
                        Text("目录为空 — 检查网关 Catalog 服务")
                            .font(.system(size: 12)).foregroundColor(.faint)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 24)
                    } else {
                        // 单张统一目录表（原生 Table）：类型成列
                        ModelTable(page: .catalog, rows: shown,
                                   selectedID: store.packSelectedID,
                                   onSelect: { store.packSelectedID = $0.isEmpty ? nil : $0 },
                                   availableWidth: w)
                            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                    }
                }
                // 宽度测在表格本体上（不含页面 padding），断点才与真实列宽一致
                .background(WidthReader(key: "packs", store: store))
                // 用户扩展能力包（统一架构 2026-11-16）：填链接 → 校验链
                CustomPackCard(store: store)
                // F4: 本机模型发现/安装（用户导入流，收进折叠区不抢主视线）
                DisclosureGroup {
                    LocalDiscoverCard(store: store).padding(.top, 4)
                } label: {
                    Text("本机模型发现").font(.system(size: 12, weight: .medium)).foregroundColor(.dim)
                }
            }
            .padding(16)
            // 详情：右侧并行栏
            if let sel {
                Divider().overlay(Color.lineC)
                ModelDetails(row: sel,
                             fields: packDetailFields(sel),
                             onClose: { store.packSelectedID = nil })
                    .frame(width: DS.Table.detailWidth)
            }
        }
        .onAppear {
            store.fetchPackCatalog()
            store.fetchPackStatus()
            store.fetchPackPolicy()
        }
    }

    // 目录行：行键 packID:variant；验证列诚实（无真实验证记录 → 待验证）
    private func packRows(_ entries: [PackCatalogEntry]) -> [ModelTableRow] {
        entries.map { entry in
            let packId = entry.pack_id
            let manifest = entry.manifest
            let templateReady = manifest.execution?.model_config_template == "llama_cpp_chat_v1"
            let rec = store.packStatus?.packs.first { $0.pack_id == packId }
            let installed = rec?.status == "installed"
            let failed = rec?.status == "failed"
            let inProgress = rec != nil && !installed && !failed
            let variant = manifest.model?.quantization
            let rowID = "\(packId)|\(variant ?? "-")"
            let sizeText: String? = {
                guard let mb = manifest.resources?.disk_mb, mb > 1 else { return nil }
                return String(format: "%.1f GB", Double(mb) / 1024.0)
            }()
            var actions: [ModelTableAction] = []
            if installed {
                actions.append(ModelTableAction(label: "卸载") { store.previewPackUninstall(packId, entry.display_name) })
            } else if inProgress {
                actions.append(ModelTableAction(label: packStageLabel(rec?.stage), disabled: true) {})
            } else if failed {
                actions.append(ModelTableAction(label: "重试", primary: true) { store.startPackInstall(packId, entry.display_name) })
            } else if templateReady {
                actions.append(ModelTableAction(label: "安装", primary: true) { store.startPackInstall(packId, entry.display_name) })
            }
            return ModelTableRow(
                id: rowID,
                title: entry.display_name,
                type: PrimaryType.from(raw: manifest.capability),
                capabilities: CapabilityTags.displayTags(capability: manifest.capability, tags: entry.tags ?? []),
                statusText: installed ? "已安装" : (failed ? "失败" : (inProgress ? "安装中" : nil)),
                target: ModelActionTarget(instanceID: packId, apiModelID: packId, packID: packId),
                actions: actions,
                variantText: variant,
                sizeText: sizeText,
                compatText: templateReady ? "llama.cpp" : "待接入",
                verificationText: nil,           // 无真实验证记录 → 共享组件显示“待验证”
                installText: installed ? "已安装" : (templateReady ? "可安装" : (inProgress ? "安装中" : (failed ? "失败" : "待接入"))))
        }
    }

    private func packDetailFields(_ row: ModelTableRow) -> [ModelDetailField] {
        var f: [ModelDetailField] = []
        if let entry = store.packCatalog?.packs.first(where: { row.id.hasPrefix("\($0.pack_id)|") }) {
            let rec = store.packStatus?.packs.first { $0.pack_id == entry.pack_id }
            f.append(ModelDetailField("包 ID", entry.pack_id))
            f.append(ModelDetailField("版本", entry.manifest.pack_version, mono: false, copyable: false))
            if let v = row.variantText { f.append(ModelDetailField("变体", v, mono: false, copyable: false)) }
            if let s = row.sizeText { f.append(ModelDetailField("体积", s, mono: false, copyable: false)) }
            if let ip = rec?.install_path { f.append(ModelDetailField("路径", ip)) }
            // 标签详情栏给全量（表格列至多主+2 修饰；spec 2026-11-17 呈现规则）
            let allTags = CapabilityTags.displayTags(capability: entry.manifest.capability,
                                                     tags: entry.tags ?? [], modifierLimit: .max)
            f.append(ModelDetailField("能力", allTags.map(\.label).joined(separator: " / "),
                                      mono: false, copyable: false))
            f.append(ModelDetailField("说明", entry.summary, mono: false, copyable: false))
            if rec?.sandbox_degraded == true {
                f.append(ModelDetailField("注意", "沙箱降级安装", mono: false, copyable: false))
            }
        }
        return f
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

/// 用户扩展能力包表单（统一架构 2026-11-16）：只填 下载链接 + 名称 + 类型，
/// 校验链在网关（格式/内存/真引擎试加载），失败给明确原因
struct CustomPackCard: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text("添加自定义能力").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                Text("填模型下载链接（GGUF · llama.cpp 框架），网关自动校验：sha256（可选）→ 格式 → 磁盘 → 真引擎试加载；失败给出明确原因，改链接后可重新提交。")
                    .font(.system(size: 10.5)).foregroundColor(.faint)
                HStack(spacing: 8) {
                    TextField("名称（如 qwen3-06b）", text: $store.customName)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .font(.system(size: 12))
                    TextField("https://…/model.gguf", text: $store.customURL)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 240)
                        .font(.system(size: 12))
                    Picker("", selection: $store.customCap) {
                        Text("对话").tag("llm")
                        Text("看图").tag("vl")
                        Text("嵌入").tag("embedding")
                    }.frame(width: 100)
                    SmallBtn(store.customBusy ? "提交中…" : "添加", primary: true) {
                        store.submitCustomPack()
                    }.disabled(store.customBusy)
                }
                TextField("sha256（可选，提供即校验）", text: $store.customSHA)
                    .textFieldStyle(.roundedBorder).frame(width: 300)
                    .font(.system(size: 11, design: .monospaced))
            }.padding(12)
        }
    }
}

/// PK4 v2：Catalog 驱动卡 — 状态机（未安装/进行中[阶段文案]/已安装/失败[重试]/
/// 待接入[运行时模板未实现，后端 preflight 亦拒]）
/// 云端接入：真数据 CRUD（GET/POST/DELETE /admin/cloud/providers + provider-models 五动作）
struct CloudView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                FeedbackBanner(store: store)
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
        store.notify(.success, "✅ 统一入口配置已复制到剪贴板")
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
                SmallBtn("关闭") { requestClose() }
            }
            HStack(spacing: 6) {
                Chip("openai", color: Color.thLlm)
                if spec.anthropic == true { Chip("anthropic", color: Color.thJudge) }
                if spec.manual == true { Chip("手填") }
                Chip(enabled ? "白名单内" : "白名单外", color: enabled ? Color.okC : Color.warnC)
            }
            VStack(alignment: .leading, spacing: 8) {
                editorToggle("视觉（VL）— VL 请求调度排最前",
                             Binding(get: { store.editorVision },
                                     set: { store.editorVision = $0; store.editorDirty = true }))
                editorToggle("工具调用 — agent/函数调用基础能力",
                             Binding(get: { store.editorTools },
                                     set: { store.editorTools = $0; store.editorDirty = true }))
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
                        // Task 9：移除成功才关闭浮窗（失败可见错误，浮窗保留）
                        store.cloudModelAction(provider, action: "remove", model: spec.id) { ok in
                            if ok { store.closeCloudModelEditor() }
                        }
                    }
                    SmallBtn("取消") { store.editorConfirmDelete = false }
                    Text("发现模型移除后不再重新出现").font(.system(size: 10.5)).foregroundColor(.faint)
                } else {
                    SmallBtn("移除此模型") { store.editorConfirmDelete = true }
                }
                Spacer()
                SmallBtn(store.editorSaving ? "保存中…" : "保存", primary: true) {
                    store.saveCloudModelEditor()
                }
                .disabled(store.editorSaving)
            }
        }
        .padding(18)
        .frame(width: 440)
        // Esc：有未保存修改先确认丢弃，不静默关闭（Task 9）
        .onExitCommand { requestClose() }
    }

    /// 关闭请求：无修改直接关；有未保存修改 → 确认丢弃
    private func requestClose() {
        guard store.editorDirty else { store.closeCloudModelEditor(); return }
        store.confirm("浮窗内有未保存的修改 — 丢弃并关闭？") {
            store.closeCloudModelEditor()
        }
    }

    private func editorToggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.system(size: 12)).foregroundColor(.ink) }
            .toggleStyle(.switch).controlSize(.small)
    }
    private func editorField(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5)).foregroundColor(.dim)
            TextField("", text: Binding(
                get: { text.wrappedValue },
                set: {
                    text.wrappedValue = $0
                    store.editorFieldErrors[title] = nil   // 修改即清错，报错不过夜
                    store.editorDirty = true
                }))
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            if let err = store.editorFieldErrors[title] {
                Text(err).font(.system(size: 10)).foregroundColor(.warnC)
            }
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
                        // Task 9：成功才更新（清空表单）；失败保留草稿可改后重试
                        store.addCloudProvider { ok in
                            guard ok else { return }
                            store.cloudFormName = ""; store.cloudFormBase = ""
                            store.cloudFormKey = ""; store.cloudFormAnth = ""
                        }
                    }
                    .disabled(store.cloudBusy)
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
        VStack(alignment: .leading, spacing: 2) {
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
            // 最后一把有效密钥撤销 = 明确风险提示（Task 9 — 鉴权仍开启，全部客户端将 401）
            if store.securityKeyRevokeConfirm == k.id, !k.revoked,
               store.securityEnforced,
               store.securityKeys.filter({ !$0.revoked }).count == 1 {
                Text("⚠️ 这是最后一把有效密钥 — 撤销后所有客户端将无法调用（鉴权仍开启，需在终端重建密钥）。确认撤销？")
                    .font(.system(size: 10.5)).foregroundColor(.warnC)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var ramGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
    private var budgetMB: Int? { store.snapshot?.status.gpu_total_mb }
    private var usedMB: Int? { store.snapshot?.status.gpu_used_mb }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 操作反馈在当前设置卡可见（Task 9 — 不只挂在别的页签）
                FeedbackBanner(store: store)
                Text("系统与账本").font(.system(size: 11)).foregroundColor(.faint)
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
                        // 保留内存只在"能力包策略"卡编辑（2026-11-16 用户裁决：
                        // 两处入口冗余，账本卡纯展示）— 账本与安装预检共用同一值
                        infoRow("为系统保留",
                                store.packPolicy.map { "\($0.system_reserved_memory_mb) MiB（能力包策略中设置）" }
                                ?? "8192 MiB（能力包策略中设置）")
                        infoRow("账本预算 B", budgetMB.map { "\($0) MB" } ?? "—（网关离线）")
                        infoRow("当前已用", usedMB.map { "\($0) MB" } ?? "—")
                    }.padding(12)
                }
                Text("安全").font(.system(size: 11)).foregroundColor(.faint)
                    .padding(.top, 4)
                // PK4: 能力包策略（4B/8GB 设置项 — spec §9 裁决）
                packPolicyCard
                // 开关项（诚实标注：已接线的可交互，未接线的保持禁用并说明）
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingRow(title: "开机时启动网关",
                                   desc: daemonDesc(store),
                                   on: store.daemonInstalled,
                                   disabled: store.daemonBusy,
                                   onToggle: { enable in
                                       if enable {
                                           store.enableDaemon()
                                       } else {
                                           // 关闭 = 停生产网关（推理中断）— 必须确认（spec 红线）
                                           store.confirm("关闭后网关不再开机自启，并会立即停止当前生产网关（:8999），正在进行的推理将中断。确认关闭？",
                                                         store.disableDaemon)
                                       }
                                   })
                        SettingRow(title: "仅本机监听",
                                   desc: "关闭后局域网设备可访问 :\(GW_PORT)（设计稿 v1.5 项，网关端点后接）",
                                   on: true, disabled: true)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("API Key 鉴权").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                                // B2：状态未知 ≠ 关闭中 — 网关不可达/未取到时如实呈现
                                let secDesc: String = {
                                    switch store.authPresentation {
                                    case .enabledAll: return "客户端需携带密钥调用 · 已登记 \(store.securityKeyCount) 把密钥"
                                    case .enabledPools: return "仅模型池请求需密钥 · 已登记 \(store.securityKeyCount) 把密钥"
                                    case .disabled: return "关闭中 — 本机任意客户端可直接调用 · 已登记 \(store.securityKeyCount) 把密钥"
                                    case .unknown: return "状态未知 — 网关不可达或未返回状态（不代表已关闭）"
                                    }
                                }()
                                Text(secDesc)
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
                            SmallBtn("＋ 新建密钥", primary: true) {
                                // Task 9：未保存明文不被第二次新建覆盖 — 有未保存
                                // 明文时先确认（密钥本身仍有效，只是不再显示）
                                if store.oneTimeKey != nil {
                                    store.confirm("上一把新密钥的明文可能尚未保存，继续新建将不再显示它（该密钥仍有效）。继续新建？") {
                                        store.createSecurityKey()
                                    }
                                } else {
                                    store.createSecurityKey()
                                }
                            }
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
                                        store.notify(.success, "✅ 密钥已复制到剪贴板")
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
            }
            .padding(16)
            .onAppear {
                store.fetchPackPolicy()
                store.refreshDaemonState()
            }
            .onChange(of: store.packPolicy) { p in
                guard let p else { return }
                store.packMaxBDraft = "\(p.max_model_parameters_b)"
                store.packReservedMBDraft = "\(p.system_reserved_memory_mb)"
            }
        }
    }

    // ── PK4: 能力包策略（4B/8GB — 仅影响后续安装，不自动重装）──
    // 草稿状态在 GatewayStore（CLT 无 SwiftUI 宏，视图内 @State 不可用 — 既有约束）
    private func savePackPolicy() {
        guard let b = Int(store.packMaxBDraft), b >= 1,
              let mb = Int(store.packReservedMBDraft), (1024...65536).contains(mb) else {
            store.notify(.error, "❌ 输入无效：参数量上限 ≥1；保留内存 1024–65536 MiB")
            return
        }
        store.savePackPolicy(b, mb)
    }

    @ViewBuilder private var packPolicyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("能力包策略").font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                HStack(spacing: 12) {
                    Text("模型参数量上限（B）").font(.system(size: 11.5)).foregroundColor(.dim)
                    TextField("4", text: $store.packMaxBDraft)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                        .font(.system(size: 12, design: .monospaced))
                    Text("系统保留内存（MiB）").font(.system(size: 11.5)).foregroundColor(.dim)
                    TextField("8192", text: $store.packReservedMBDraft)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    SmallBtn("保存", primary: true) { savePackPolicy() }
                }
                Text("仅作用于能力包安装预检（对话类 LLM/VL 参数量门禁 + 内存预算），不自动重装、不自动启动。")
                    .font(.system(size: 10.5)).foregroundColor(.faint)
                // 预设安装路径说明（2026-11-16 用户裁决：展示 + 预设说明）
                infoRow("安装位置", "~/.inferfabric/packs/<包名>/<版本>（预设）")
                    .padding(.top, 2)
            }.padding(12)
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
    var onToggle: ((Bool) -> Void)? = nil

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
                Toggle("", isOn: Binding(
                    get: { on },
                    set: { onToggle?($0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .controlSize(.small).disabled(disabled).opacity(disabled ? 0.6 : 1)
            }
        }
        .padding(.vertical, 10)
        Divider().overlay(Color.lineC)
    }
}

/// 守护 Toggle 呈现文案：三态诚实（含运行 pid），操作中显示进行中
private func daemonDesc(_ store: GatewayStore) -> String {
    if store.daemonBusy { return "操作进行中…" }
    if let pid = store.daemonRunningPID {
        return "已使能 · 运行中 (pid \(pid)) — 登录自启、崩溃自愈"
    }
    if store.daemonInstalled {
        return "已使能 · 当前未运行 — 登录时自启、崩溃自愈"
    }
    return "关闭中 — 开启后登录自启、崩溃自愈（服务 :8999）"
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
                        .fill(i <= ws.page ? Color.accent : Color.washStrong)
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
                poolRow("fabric-fast", "快速对话 · 低延迟优先", "qwen3-4b → glm-5")
                poolRow("fabric-small", "轻量任务 · 意图分类", "qwen3-4b → glm-5-flash")
                poolRow("fabric-premium", "高质量长文", "glm-5（云端）")
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
        .background(Color.washFaint, in: RoundedRectangle(cornerRadius: 9))
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
        .background(Color.washFaint, in: RoundedRectangle(cornerRadius: 7))
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
        segs.append((Color.wash, total > 0 ? max(1 - used / total, 0.02) : 1.0))
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
    // 进程级强持有：main.swift 顶层 let 是 main() 局部变量，会被 ARC 提前释放，
    // 而 NSApplication.delegate 是 unsafe unretained —— 曾导致回调打野指针崩溃
    // 且 applicationDidFinishLaunching 不执行（窗口永不出现）。static let 永生。
    static let shared = AppDelegate()
    let store = GatewayStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var wizardWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        // 不设 appearance —— 跟随系统深浅色（批 2：解除浅色固定）
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
            // 调试启动参数（视觉验收矩阵用；正式行为不受影响）：
            //   -page N  初始页（0总览/1模型服务/2本地推理/3模型池/4监控台/5能力包/6云端接入/7设置）
            //   -size WxH 窗口内容尺寸
            let argv = ProcessInfo.processInfo.arguments
            // 调试启动参数（视觉验收矩阵用；正式行为不受影响）：
            //   -appearance dark|light  覆盖本进程外观（缺省跟随系统）
            if let i = argv.firstIndex(of: "-appearance"), i + 1 < argv.count {
                NSApp.appearance = NSAppearance(named: argv[i + 1] == "dark" ? .darkAqua : .aqua)
            }
            var width = 960.0, height = 620.0
            if let i = argv.firstIndex(of: "-size"), i + 1 < argv.count {
                let wh = argv[i + 1].split(separator: "x").compactMap { Double($0) }
                if wh.count == 2, wh[0] >= 480, wh[1] >= 400 {
                    width = wh[0]; height = wh[1]
                }
            }
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "MacFabric"
            win.center()
            win.delegate = self
            win.backgroundColor = .windowBackgroundColor   // 语义自适应（批 2）
            window = win
            if let i = argv.firstIndex(of: "-page"), i + 1 < argv.count, let p = Int(argv[i + 1]) {
                store.tab = p
            }
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
app.delegate = AppDelegate.shared
app.setActivationPolicy(.regular)
app.run()
