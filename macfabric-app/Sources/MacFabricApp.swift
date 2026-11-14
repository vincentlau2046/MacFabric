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
    static let desk = Color(hex: 0x101014)      // 桌面
    static let panel = Color(hex: 0x17171c)     // 窗口面板
    static let chrome = Color(hex: 0x1e1e25)    // 标题栏
    static let glass = Color.white.opacity(0.055)
    static let lineC = Color.white.opacity(0.10)
    static let ink = Color(hex: 0xf5f5f7)
    static let dim = Color(hex: 0xa3a3ad)
    static let faint = Color(hex: 0x6d6d78)
    static let accent = Color(hex: 0x5f7dff)    // 织物蓝
    static let okC = Color(hex: 0x32d74b)
    static let warnC = Color(hex: 0xffd60a)
    // 能力线色（九根线 = 九类能力）
    static let thJudge = Color(hex: 0xc79bff)
    static let thLlm = Color(hex: 0x7a8cff)
    static let thVl = Color(hex: 0xff7fa3)
    static let thEmb = Color(hex: 0x4fd8b8)
    static let thRerank = Color(hex: 0x66b8ff)
    static let thAsr = Color(hex: 0xffc266)
    static let thTts = Color(hex: 0xff8f6b)
    static let thOcr = Color(hex: 0xa8e063)
    static let thImg = Color(hex: 0x6fe0e0)
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
    var ledgerMode: String { ledger_mode ?? "on_demand" }
}

struct CurvePoint: Codable {
    var t: Double
    var tokens: Int
    var requests: Int
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
    @Published var actionMessage = ""
    @Published var hubExpanded = ""
    var onMemoryInsufficient: ((_ name: String, _ reason: String) -> Void)?

    private let base = URL(string: "http://127.0.0.1:8999")!
    private var timer: Timer?
    private var curveTimer: Timer?

    init() {
        refresh(); fetchModels(); fetchCurve()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh(); self?.fetchModels()
        }
        curveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.fetchCurve()
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
        var req = URLRequest(url: base.appendingPathComponent("/v1/chat/completions"), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "qwen3-4b", "max_tokens": 300,
            "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": prompt]],
        ])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            defer { DispatchQueue.main.async { self?.busy = false } }
            guard let self, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                DispatchQueue.main.async { self?.reply = "请求失败（网关未响应或模型未加载）" }
                return
            }
            DispatchQueue.main.async { self.reply = content }
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
        .background(Color.white.opacity(0.035))
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
        .background(Color.white.opacity(0.028))
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
    var store: GatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(store.gatewayUp ? Color.okC : Color.red).frame(width: 9, height: 9)
                    Text(store.gatewayUp ? "网关运行中 :8999" : "网关未响应")
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
                    StatCard(v: store.gatewayUp ? "在线" : "离线", k: "网关 :8999")
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
        segs.append(WeaveSeg(color: Color.white.opacity(0.05), ratio: store.freeRatio, name: "空闲",
                     gb: String(format: "%.1f", Double(max(store.budgetMB - store.usedMB - store.reserveMB, 0)) / 1024)))
        segs.append(WeaveSeg(color: Color.white.opacity(0.10), ratio: Double(store.reserveMB) / Double(max(store.budgetMB, 1)), name: "系统保留", gb: "8.0"))
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
    var store: GatewayStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    HStack(spacing: 10) {
                        Chip("接入地址")
                        Text("http://127.0.0.1:8999").font(.system(size: 12, design: .monospaced)).foregroundColor(.ink)
                        Chip("鉴权未启用")
                        Spacer()
                        CopyButton("复制 Base URL", text: "http://127.0.0.1:8999", small: true)
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
                        FieldRow(k: "OpenAI", v: "http://127.0.0.1:8999/v1 · 模型 ID: \(model.name)")
                        FieldRow(k: "Anthropic", v: "http://127.0.0.1:8999 · ANTHROPIC_MODEL=\(model.name)")
                        CopyButton("复制环境变量", text: "export ANTHROPIC_BASE_URL=http://127.0.0.1:8999\nexport ANTHROPIC_MODEL=\(model.name)", small: true)
                        Text("已停止的按需模型照样能调 — 首请求自动唤醒，约 2s")
                            .font(.system(size: 10.5)).foregroundColor(.faint)
                    }
                    .padding(.leading, 12).padding(.bottom, 10).padding(.trailing, 12)
                }
            }
        }
    }
    var configJSON: String {
        "{\"base_url\": \"http://127.0.0.1:8999/v1\", \"model\": \"\(model.name)\", \"api_key\": \"未启用鉴权\"}"
    }
    var curlFor: String {
        "curl http://127.0.0.1:8999/v1/chat/completions -H \"Content-Type: application/json\" -d '{\"model\":\"\(model.name)\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
    }
}

struct Chip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundColor(.dim)
            .padding(.horizontal, 9).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.lineC, lineWidth: 1))
            .background(Color.white.opacity(0.03), in: Capsule())
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
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
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
    var store: GatewayStore
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
                Chip(loadChip)                       // 装载模式 chip
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
    let action: () -> Void
    init(_ title: String, primary: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.primary = primary; self.action = action
    }
    var body: some View {
        Button(title, action: action)
            .font(.system(size: 11.5, weight: primary ? .semibold : .regular))
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(primary ? Color.accent : Color.white.opacity(0.06),
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
            Text("试聊 · 经 :8999 网关").font(.system(size: 11.5)).foregroundColor(.faint)
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

/// 设计稿默认池五件套（v1 静态目录，候选点亮跟实际运行态走）
let defaultPools: [(String, String, [(String, String, Bool)])] = [
    ("iff/fast", "快速对话",
     [("1", "qwen3-4b", true), ("2", "glm-5", false)]),
    ("iff/small", "轻量任务 · 意图分类",
     [("1", "qwen3-1.7b", true), ("2", "glm-5-flash", false)]),
    ("iff/premium", "高质量长文",
     [("1", "glm-5", false)]),
    ("iff/txt2img", "文生图",
     [("1", "mflux-schnell", true), ("2", "seedream-4.0", false)]),
    ("iff/img2img", "图生图 · 编辑",
     [("1", "mflux-schnell-edit", true), ("2", "seedream-edit", false)]),
]

struct PoolsView: View {
    var store: GatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !store.actionMessage.isEmpty {
                    Text(store.actionMessage).font(.system(size: 12))
                        .padding(8).frame(maxWidth: .infinity)
                        .background(Color.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 12) {
                    ForEach(defaultPools, id: \.0) { pool in
                        PoolCard(store: store, name: pool.0, use: pool.1, candidates: pool.2)
                    }
                }
                Text("嵌入与重排不入池 — 基本不更换的能力走静态直连；池配置当前为规划目录，网关侧 iff/<pool> 路由接入后此页即实时")
                    .font(.system(size: 11)).foregroundColor(.faint)
            }.padding(16)
        }
    }
}

struct PoolCard: View {
    var store: GatewayStore
    let name: String
    let use: String
    let candidates: [(String, String, Bool)]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                    Text(use).font(.system(size: 11.5)).foregroundColor(.dim)
                    Spacer()
                    let onCount = candidates.filter { isCandidateActive($0.1) }.count
                    Text(onCount > 0 ? "● 调用中" : "\(onCount) 就绪")
                        .font(.system(size: 11)).foregroundColor(onCount > 0 ? .okC : .faint)
                }
                ForEach(candidates, id: \.1) { c in
                    HStack(spacing: 8) {
                        Text(c.0).font(.system(size: 11, design: .monospaced)).foregroundColor(.faint)
                            .frame(width: 12)
                        Circle().fill(isCandidateActive(c.1) ? Color.okC : Color.faint.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(c.1).font(.system(size: 12.5)).foregroundColor(.ink)
                        Chip(isLocal(c.1) ? "本机" : "云端")
                        Spacer()
                        Text(isCandidateActive(c.1) ? "调用中" : "待命")
                            .font(.system(size: 11)).foregroundColor(isCandidateActive(c.1) ? .okC : .dim)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(12)
        }
    }

    func isLocal(_ name: String) -> Bool {
        store.models.contains { $0.name == name }
    }
    func isCandidateActive(_ name: String) -> Bool {
        store.models.first { $0.name == name }?.active == true
    }
}

struct MonitorView: View {
    var store: GatewayStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    StatCard(v: "\(store.totalRequests)", k: "24h 请求")
                    StatCard(v: "\(store.totalTokens)", k: "24h tokens")
                    StatCard(v: store.gatewayUp ? "在线" : "离线", k: "网关状态")
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
            }.padding(18)
        }
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
        .preferredColorScheme(.dark)
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
    var store: GatewayStore

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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(packs, id: \.1) { pk in
                    PackCard(store: store, pack: pk)
                }
            }
            .padding(16)
        }
    }
}

struct PackCard: View {
    var store: GatewayStore
    let pack: (String, String, String, String?, String?)

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
                    } else {
                        Text("安装").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Color.accent, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.white)
                            .help("能力包安装将写入 models.d（P3 端点落地后启用）")
                            .onHover { _ in }
                    }
                }
            }
            .padding(12)
        }
    }
}

/// 云端接入：服务商行 + 云端模型卡（v1 静态演示目录，/admin/cloud 数据接入后实时）
struct CloudView: View {
    var store: GatewayStore

    let providers: [(String, String, String, String)] = [
        ("智", "#3b6cff", "智谱AI", "OpenAI + Anthropic · 自动发现 3 个模型"),
        ("深", "#2b7de1", "DeepSeek", "OpenAI · 自动发现 2 个模型"),
        ("火", "#7a5cf0", "火山方舟", "OpenAI · 自动发现 4 个模型"),
        ("百", "#8a8a95", "百度千帆", "规格预设 · 无 /models 端点，手工声明模型"),
    ]
    let cloudModels: [(String, String)] = [
        ("glm-5", "智谱AI · 旗舰 · OpenAI + Anthropic"),
        ("glm-5-flash", "智谱AI · 快速 · OpenAI"),
        ("deepseek-v4", "DeepSeek · 推理 · OpenAI"),
        ("seedream-4.0", "火山方舟 · 图像 · OpenAI"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(providers, id: \.2) { pv in
                            HStack(spacing: 10) {
                                Text(pv.0).font(.system(size: 14, weight: .bold))
                                    .frame(width: 26, height: 26)
                                    .background(Color(hexString: pv.1), in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundColor(.white)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(pv.2).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                                    Text(pv.3).font(.system(size: 11)).foregroundColor(.dim)
                                }
                                Spacer()
                                Chip(pv.2 == "百度千帆" ? "未测试" : "已连接")
                                SmallBtn("测试") {}
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(cloudModels, id: \.0) { cm in
                        Card {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(cm.0).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                                Text(cm.1).font(.system(size: 11.5)).foregroundColor(.dim).lineLimit(2)
                                HStack {
                                    Spacer()
                                    Chip("未入池 · 演示目录")
                                }
                            }.padding(12)
                        }
                    }
                }
                Text("统一入口 :8999 覆盖全部类型：/v1/chat/completions · /v1/messages · /v1/embeddings · /v1/audio/* · /v1/images/* · /ocr — 本地与云端候选共用同一调用面")
                    .font(.system(size: 11)).foregroundColor(.faint)
            }.padding(16)
        }
    }
}

extension Color {
    init(hexString: String) {
        let h = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(hex: UInt32(v))
    }
}

/// 设置：审查钉死的默认值都编码在这里（v1 展示真实值；开关后接 admin 端点）
struct SettingsView: View {
    var store: GatewayStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(title: "开机时启动网关",
                           desc: "通过系统 LaunchAgent 常驻，App 不开也在服务（需在终端执行 scripts/install-launchd.sh install 批准）",
                           on: false)
                SettingRow(title: "HuggingFace 镜像加速",
                           desc: "模型下载走 hf-mirror.com，国内网络建议开启",
                           on: true)
                SettingRow(title: "仅本机监听",
                           desc: "关闭后局域网设备可访问 :8999，将强制启用 API 鉴权",
                           on: true)
                SettingRow(title: "API Key 鉴权",
                           desc: "客户端需携带密钥调用，密钥仅生成时展示一次",
                           on: false)
                SettingRow(title: "模型目录",
                           desc: "模型文件与引擎环境所在位置",
                           path: "/Users/Apple/Documents/MacFabric/models")
                SettingRow(title: "内存保留",
                           desc: "为系统与其他 App 保留的内存 — 全局唯一公式 B = RAM − 8G 的唯一入口，无第二道上限",
                           path: "8 GB")
                SettingRow(title: "检查更新",
                           desc: "llama.cpp b12361 · 引擎目录 engines/llama-b12361",
                           path: nil, button: "检查")
            }.padding(16)
        }
    }
}

struct SettingRow: View {
    let title: String
    let desc: String
    var on = false
    var path: String? = nil
    var button: String? = nil

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
                Toggle("", isOn: .constant(on)).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        .padding(.vertical, 10)
        Divider().overlay(Color.lineC)
    }
}

// ─── AppKit 引导：菜单栏常驻 + 主窗口 ───────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = GatewayStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenuBarItem()
        store.onMemoryInsufficient = { [weak self] name, reason in
            self?.showMemoryDialog(name: name, reason: reason)
        }
        showOverview()
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
        let overview = NSMenuItem(title: "打开总览", action: #selector(showOverview), keyEquivalent: "o")
        overview.target = self
        menu.addItem(overview)
        let dash = NSMenuItem(title: "打开网关面板 :8999", action: #selector(openDashboard), keyEquivalent: "d")
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
            win.backgroundColor = NSColor(red: 0x10/255, green: 0x10/255, blue: 0x14/255, alpha: 1)
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
        if let url = URL(string: "http://127.0.0.1:8999/") { NSWorkspace.shared.open(url) }
    }
}

// ─── main ──────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
