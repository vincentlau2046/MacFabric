// 产品资料共享合同（UI v2 + 产品定义 v2 的 App 侧单一事实源）
// 纯 Foundation/CoreGraphics，无 SwiftUI 依赖 — 契约测试直接编译本文件。
// 规则：未知类型不得默认“对话”；显示名不得由 slug 反推；未知资源显示“未知”；
// 示例只用密钥占位符；预算 reserve 只扣一次；网关不可达 ≠ 鉴权未启用。
import Foundation
import CoreGraphics

// ── 类型 ───────────────────────────────────────────────────────

enum PrimaryType: String, CaseIterable, Equatable {
    case llm, vl, embedding, rerank, asr, tts, ocr, aigc
    case unknown

    var displayName: String {
        switch self {
        case .llm: "文本生成"
        case .vl: "视觉理解"
        case .embedding: "文本嵌入"
        case .rerank: "相关性重排"
        case .asr: "语音识别"
        case .tts: "语音合成"
        case .ocr: "文字识别"
        case .aigc: "图像生成"
        case .unknown: "未知类型"
        }
    }

    /// 后端原始类型串 → 类型。nil/未识别一律 .unknown，绝不回退 .llm。
    static func from(raw: String?) -> PrimaryType {
        guard let raw, let t = PrimaryType(rawValue: raw) else { return .unknown }
        return t
    }
}

// ── 身份 ───────────────────────────────────────────────────────

/// 三层身份：instanceID（内部生命周期键）／displayName（官方模型名）／apiModelID（公开调用名）。
/// displayName 缺失时诚实回退 instanceID 并标注 fallback — 禁止“去 pack- 前缀”式猜测。
struct ProductIdentity: Equatable {
    let instanceID: String
    let displayName: String
    let apiModelID: String?
    let displayNameIsFallback: Bool

    init(instanceID: String, displayName: String?, apiModelID: String?, packID: String? = nil) {
        self.instanceID = instanceID
        if let d = displayName, !d.isEmpty {
            self.displayName = d
            self.displayNameIsFallback = false
        } else {
            self.displayName = instanceID
            self.displayNameIsFallback = true
        }
        self.apiModelID = apiModelID
    }
}

/// 本地公开调用 ID 规范（产品定义 v2 §3.1）：小写字母/数字/连字符，≤96；
/// 保留前缀 pack-/fabric-/cloud- 拒绝（云端/池 ID 不走本校验）。
enum APIIdentity {
    static func validate(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 96 else { return nil }
        guard let first = id.first, (first.isLowercase && first.isASCII) || (first.isNumber && first.isASCII) else { return nil }
        for prefix in ["pack-", "fabric-", "cloud-"] where id.hasPrefix(prefix) { return nil }
        var prevDash = false
        for ch in id {
            let ok = (ch.isLowercase && ch.isASCII) || (ch.isNumber && ch.isASCII) || ch == "-"
            guard ok else { return nil }
            if ch == "-" {
                if prevDash { return nil }
                prevDash = true
            } else { prevDash = false }
        }
        return id.hasSuffix("-") ? nil : id
    }
}

// ── 运行/安装/兼容/验证状态（彼此独立，不合并语义）────────────────

enum RunState: Equatable {
    case available, notLoaded, loading, sleeping, error
    var label: String {
        switch self {
        case .available: "可用"
        case .notLoaded: "未加载"
        case .loading: "加载中"
        case .sleeping: "已睡眠"
        case .error: "异常"
        }
    }
}

enum Source: Equatable {
    case local
    case cloud(provider: String)
    case pool(name: String)
    var label: String {
        switch self {
        case .local: "本地模型"
        case .cloud(let p): "云端 · \(p)"
        case .pool(let n): "模型池 · \(n)"
        }
    }
}

// ── 模型行 ─────────────────────────────────────────────────────

/// 能力标签（spec §3.2）：id/label；verification/evidence_ref 进详情。
struct CapabilityTag: Decodable, Equatable {
    let id: String
    let label: String

    init(id: String, label: String) { self.id = id; self.label = label }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.init(id: s, label: s)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let i = try c.decode(String.self, forKey: .id)
            self.init(id: i, label: (try? c.decodeIfPresent(String.self, forKey: .label)) ?? i)
        }
    }
    private enum CodingKeys: String, CodingKey { case id, label }
}

struct ProductModel: Identifiable, Equatable, Decodable {
    let id: String                     // instance_id — 行身份与操作目标
    let displayName: String
    let displayNameIsFallback: Bool
    let type: PrimaryType
    let apiModelID: String?
    let capabilities: [CapabilityTag]
    let active: Bool
    let sleeping: Bool
    let healthError: Bool
    let memoryBaselineMB: Int?
    let variant: String?
    let packID: String?
    let source: Source

    init(id: String, displayName: String?, type: PrimaryType, apiModelID: String? = nil,
         capabilities: [CapabilityTag] = [], active: Bool = false, sleeping: Bool = false,
         healthError: Bool = false, memoryBaselineMB: Int? = nil, variant: String? = nil,
         packID: String? = nil, source: Source = .local) {
        let ident = ProductIdentity(instanceID: id, displayName: displayName, apiModelID: apiModelID)
        self.id = id
        self.displayName = ident.displayName
        self.displayNameIsFallback = ident.displayNameIsFallback
        self.type = type
        self.apiModelID = apiModelID
        self.capabilities = capabilities
        self.active = active
        self.sleeping = sleeping
        self.healthError = healthError
        self.memoryBaselineMB = memoryBaselineMB
        self.variant = variant
        self.packID = packID
        self.source = source
    }

    var runState: RunState {
        if healthError { return .error }
        if sleeping { return .sleeping }
        if active { return .available }
        return .notLoaded
    }

    // A2 product_record 同源解码：蛇形键；未知 nullable；云端/池来源保留原始 ID。
    private enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id", displayName = "display_name", apiModelID = "api_model_id"
        case primaryType = "primary_type", capabilities, active, sleeping
        case healthError = "health_error"
        case memoryBaselineMB = "memory_baseline_mb", variant
        case packID = "pack_id", source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .instanceID)
        let name = try c.decodeIfPresent(String.self, forKey: .displayName)
        let type = PrimaryType.from(raw: try c.decodeIfPresent(String.self, forKey: .primaryType))
        let apiID = try c.decodeIfPresent(String.self, forKey: .apiModelID)
        let caps = (try? c.decodeIfPresent([CapabilityTag].self, forKey: .capabilities)) ?? []
        let isActive = (try? c.decodeIfPresent(Bool.self, forKey: .active)) ?? false
        let isSleeping = (try? c.decodeIfPresent(Bool.self, forKey: .sleeping)) ?? false
        let isUnhealthy = (try? c.decodeIfPresent(Bool.self, forKey: .healthError)) ?? false
        let mem = try c.decodeIfPresent(Int.self, forKey: .memoryBaselineMB)
        let variant = try c.decodeIfPresent(String.self, forKey: .variant)
        let pack = try c.decodeIfPresent(String.self, forKey: .packID)
        let src = Self.decodeSource(try c.decodeIfPresent(SourceValue.self, forKey: .source))
        self.init(id: id, displayName: name, type: type, apiModelID: apiID,
                  capabilities: caps, active: isActive, sleeping: isSleeping,
                  healthError: isUnhealthy, memoryBaselineMB: mem, variant: variant,
                  packID: pack, source: src)
    }

    /// 来源对象 {kind, provider}；缺省本地。
    private struct SourceValue: Decodable {
        let kind: String?
        let provider: String?
    }
    private static func decodeSource(_ v: SourceValue?) -> Source {
        guard let v else { return .local }
        return switch v.kind {
        case "cloud": .cloud(provider: v.provider ?? "未知来源")
        case "pool": .pool(name: v.provider ?? "")
        default: .local
        }
    }
}

// ── 资源与预算（唯一口径；reserve 只扣一次）─────────────────────

enum MemoryMath {
    /// 内存基线文案：nil → “未知”，非 0 → 约 X.X GiB（1024 换算）
    static func baselineText(mb: Int?) -> String {
        guard let mb, mb > 0 else { return "未知" }
        return String(format: "约 %.1f GiB", Double(mb) / 1024)
    }

    /// 可用预算 = 总量 − 已用 − reserve（单次扣减；调用方不得再传已扣值）
    static func freeBudgetMB(total: Int, used: Int, reserve: Int) -> Int {
        max(total - used - reserve, 0)
    }
}

// ── 列断点（UI v2 §3；W = 内容区可用宽度）──────────────────────

enum ModelColumnLayout {
    enum ColumnID: Equatable {
        case name, type, capabilities, status, memory, actions
        case variant, size, compat, verification, install, source
    }
    enum Page { case localInference, catalog, hub }

    /// 共享列定义：断点收列顺序 — 先能力，再资源/来源，目录页变体/体积/验证随能力列同收。
    /// 名称/类型/状态/动作恒在；不产生整表横向滚动。
    static func visibleColumns(page: Page, availableWidth: CGFloat) -> [ColumnID] {
        let full = availableWidth >= 1100
        let mid = availableWidth >= 820
        switch page {
        case .localInference:
            var cols: [ColumnID] = [.name, .type]
            if full { cols.append(.capabilities) }
            cols.append(.status)
            if mid { cols.append(.memory) }
            cols.append(.actions)
            return cols
        case .hub:
            var cols: [ColumnID] = [.name, .type]
            if mid { cols.append(.source) }
            cols.append(.status)
            cols.append(.actions)
            return cols
        case .catalog:
            var cols: [ColumnID] = [.name, .type]
            if full { cols.append(.capabilities) }
            if full { cols.append(.variant) }
            if full { cols.append(.size) }
            // 中窄：兼容/验证合并展示为两行“准入”，数据维度不丢
            cols.append(.compat)
            if full { cols.append(.verification) }
            cols.append(.install)
            cols.append(.actions)
            return cols
        }
    }
}

// ── 按能力端点与示例（密钥只用占位符）───────────────────────────

enum APIExamples {
    static let credentialPlaceholder = "YOUR_GATEWAY_API_KEY"
    static let envPlaceholder = "$MACFABRIC_API_KEY"

    /// 类型 → 实际支持的端点路径；未知/未交付类型返回 nil（不生成伪有效配置）
    static func endpoint(for type: PrimaryType) -> String? {
        switch type {
        case .llm, .vl: "/v1/chat/completions"
        case .embedding: "/v1/embeddings"
        case .rerank: "/v1/rerank"
        case .aigc: "/v1/images/generations"
        case .asr: "/v1/audio/transcriptions"
        case .tts: "/v1/audio/speech"
        case .ocr: "/ocr"
        case .unknown: nil
        }
    }

    static func make(modelID: String, type: PrimaryType, baseURL: String, format: Format) -> String? {
        guard let path = endpoint(for: type), !modelID.isEmpty else { return nil }
        let url = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        switch format {
        case .curl: return curlExample(modelID: modelID, type: type, url: url)
        case .json: return jsonConfig(modelID: modelID, baseURL: baseURL)
        case .env: return envConfig(modelID: modelID, baseURL: baseURL)
        }
    }

    enum Format: String { case curl, json, env }

    private static func body(for type: PrimaryType, modelID: String) -> [String: Any] {
        switch type {
        case .embedding: return ["model": modelID, "input": "寻找相近的句子"]
        case .rerank: return ["model": modelID, "query": "如何整理本地文档？",
                              "documents": ["文档分类与归档", "今天的天气预报"]]
        case .vl: return ["model": modelID, "messages": [["role": "user", "content": [
            ["type": "text", "text": "这张图是什么？"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,<IMAGE_BASE64>"]]]]]]
        case .aigc: return ["model": modelID, "prompt": "织物纹理的抽象插画"]
        default: return ["model": modelID, "messages": [["role": "user", "content": "你好"]]]
        }
    }

    private static func curlExample(modelID: String, type: PrimaryType, url: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body(for: type, modelID: modelID),
                                                     options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: data, encoding: .utf8) else { return "" }
        return "curl \(url) \\\n  -H \"Authorization: Bearer \(envPlaceholder)\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '\(pretty)'"
    }

    private static func jsonConfig(modelID: String, baseURL: String) -> String {
        "{\n  \"base_url\": \"\(baseURL)/v1\",\n  \"model\": \"\(modelID)\",\n  \"api_key\": \"\(credentialPlaceholder)\"\n}"
    }

    private static func envConfig(modelID: String, baseURL: String) -> String {
        "export OPENAI_BASE_URL=\(baseURL)/v1\nexport OPENAI_API_KEY=\(envPlaceholder)\nexport OPENAI_MODEL=\(modelID)"
    }
}

// ── 试用目标（试聊只认活跃 LLM，绝不回退首个模型）───────────────

enum TryoutPolicy {
    static func pickChatTarget(_ models: [ProductModel]) -> ProductModel? {
        models.first { $0.type == .llm && $0.active && !$0.healthError }
    }
}

// ── 鉴权呈现（未知 ≠ 未启用）───────────────────────────────────

enum AuthPresentation: Equatable {
    case enabledAll, enabledPools, disabled, unknown

    /// policy 来自后端 /admin/security/status；网关不可达或未取到时一律 .unknown，
    /// 绝不把失败解释为“未启用”。
    static func present(policy: String?, gatewayUp: Bool, fetched: Bool) -> AuthPresentation {
        guard gatewayUp, fetched else { return .unknown }
        return switch policy {
        case "all": .enabledAll
        case "pools": .enabledPools
        case "off": .disabled
        default: .unknown
        }
    }

    static func text(for state: AuthPresentation) -> String {
        switch state {
        case .enabledAll: "已启用 · 全部请求"
        case .enabledPools: "仅模型池请求"
        case .disabled: "未启用"
        case .unknown: "状态未知"
        }
    }

    /// 实例形式（UI 调用点更直观）；与 text(for:) 同源。
    var text: String { AuthPresentation.text(for: self) }
}

// ── 监控行身份（同名不同实例不合并）────────────────────────────

enum MonitorIdentity {
    static func key(location: String, provider: String, model: String) -> String {
        "\(location)|\(provider)|\(model)"
    }
}

// ── B3：操作目标 / 列表逻辑 / 选择保持 ─────────────────────────

/// 操作目标三分：启停用 instanceID、推理用 apiModelID、安装卸载用 packID。
/// 状态改变刷新绝不以 displayName 索引。
struct ModelActionTarget: Equatable {
    let instanceID: String
    let apiModelID: String
    let packID: String?
}

extension ProductModel {
    var actionTarget: ModelActionTarget {
        ModelActionTarget(instanceID: id, apiModelID: apiModelID ?? id, packID: packID)
    }
}

/// 列表排序/过滤：活跃在前、同名按 id 稳定；筛选不改变实例身份集合。
enum ModelListLogic {
    static func apply(_ models: [ProductModel], query: String, typeFilter: PrimaryType?) -> [ProductModel] {
        let q = query.lowercased()
        let matched = models.filter { m in
            let typeOK = typeFilter == nil || m.type == typeFilter
            let queryOK = q.isEmpty
                || m.displayName.lowercased().contains(q)
                || m.id.lowercased().contains(q)
                || (m.apiModelID?.lowercased().contains(q) ?? false)
            return typeOK && queryOK
        }
        return matched.sorted { a, b in
            if a.active != b.active { return a.active }
            if a.displayName != b.displayName { return a.displayName < b.displayName }
            return a.id < b.id
        }
    }
}

/// 刷新保持选中：选中项仍在则保留；被移除才清空（不以 displayName 索引）。
struct SelectionKeeper {
    var selectedID: String?
    mutating func refresh(availableIDs: [String]) {
        if let s = selectedID, !availableIDs.contains(s) { selectedID = nil }
    }
}
