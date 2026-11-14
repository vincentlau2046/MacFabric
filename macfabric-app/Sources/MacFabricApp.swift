// MacFabric 原生 App — P2 骨架（无 Xcode / 无 SwiftUI 宏，CLT 直编）
// 架构：AppKit 引导（NSStatusItem 菜单栏 + NSWindow）+ NSHostingView 承载 SwiftUI。
// 状态集中 GatewayStore（@Published 仍是普通属性包装，可用）；
// SwiftUI 外部宏包装（@State/@StateObject/@ObservedObject/@Environment）在 CLT
// 缺 SwiftUIMacros 插件，一律改手动 Binding / 传参。
import SwiftUI
import Charts
import Combine
import AppKit

// ─── 数据模型 ──────────────────────────────────────────────────

struct Snapshot: Codable {
    struct Status: Codable {
        var gpu_mode: String?
        var active_services: [String]?
        var services_health: [String: String]?
        var services_info: [String: ServiceInfo]?
        var gpu_used_mb: Int?
        var gpu_total_mb: Int?
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

    private let base = URL(string: "http://127.0.0.1:8999")!
    private var timer: Timer?
    private var curveTimer: Timer?

    init() {
        refresh()
        fetchModels()
        fetchCurve()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.fetchModels()
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
                    self.snapshot = snap
                    self.gatewayUp = true
                } else {
                    self.gatewayUp = false
                }
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
                return CurvePoint(t: t,
                                  tokens: (d["tokens"] as? Int) ?? Int((d["tokens"] as? Double) ?? 0),
                                  requests: (d["requests"] as? Int) ?? Int((d["requests"] as? Double) ?? 0))
            }
            DispatchQueue.main.async { self.curve = pts }
        }.resume()
    }

    /// POST /switch 或 /stop（admin 动作，body {"model": name}）
    private func adminAction(_ path: String, model: String, done: @escaping (String) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                let ok = (200..<300).contains(code)
                done(ok ? "✅ \(model) 完成"
                        : "❌ \(model) 失败(\(code)): \(body.prefix(120))")
                self?.refresh(); self?.fetchModels()
            }
        }.resume()
    }

    func switchModel(_ name: String, then: ((Bool) -> Void)? = nil) {
        actionMessage = "切换 \(name) 中…（首次加载约 5~10s）"
        adminAction("/switch", model: name) { [weak self] msg in
            self?.actionMessage = msg
            then?(msg.hasPrefix("✅"))
        }
    }

    func stopService(_ name: String) {
        actionMessage = "停止 \(name) 中…"
        adminAction("/stop", model: name) { [weak self] msg in
            self?.actionMessage = msg
        }
    }

    var usedGB: String {
        guard let u = snapshot?.status.gpu_used_mb else { return "—" }
        return String(format: "%.1f", Double(u) / 1024)
    }
    var budgetGB: String {
        guard let t = snapshot?.status.gpu_total_mb, t > 0 else { return "—" }
        return String(format: "%.0f", Double(t) / 1024)
    }
    var usageRatio: Double {
        guard let u = snapshot?.status.gpu_used_mb,
              let t = snapshot?.status.gpu_total_mb, t > 0 else { return 0 }
        return min(Double(u) / Double(t), 1)
    }

    func sendPrompt() {
        busy = true; reply = ""
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8999/v1/chat/completions")!)
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
}

// ─── SwiftUI 视图（无宏写法）────────────────────────────────────

struct OverviewView: View {
    @ObservedObject var store: GatewayStore  // 观察宏缺失：退化为普通引用，靠 store 轮询驱动

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Circle().fill(store.gatewayUp ? Color.green : Color.red).frame(width: 10, height: 10)
                Text(store.gatewayUp ? "网关运行中 :8999" : "网关未响应").font(.headline)
                Spacer()
                Button("刷新") { store.refresh() }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("统一内存").font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                    Text("\(store.usedGB) GB / 预算 \(store.budgetGB) GB")
                        .font(.subheadline.monospacedDigit())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(store.usageRatio > 0.9 ? Color.red : Color.blue)
                            .frame(width: geo.size.width * store.usageRatio)
                    }
                }
                .frame(height: 10)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Label(store.snapshot?.status.gpu_mode ?? "idle", systemImage: "cpu")
                Spacer()
                Text("活跃服务 \(store.snapshot?.status.active_services?.count ?? 0)")
                    .foregroundColor(.secondary)
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(20)
    }
}

struct ServicesView: View {
    var store: GatewayStore

    var body: some View {
        List {
            let services = store.snapshot?.status.active_services ?? []
            if services.isEmpty {
                Text("无运行中的模型服务").foregroundColor(.secondary)
            }
            ForEach(services, id: \.self) { name in
                HStack {
                    Image(systemName: "cube.transparent").foregroundColor(.blue)
                    Text(name)
                    Spacer()
                    Text(store.snapshot?.status.services_health?[name] ?? "?")
                    if let port = store.snapshot?.status.services_info?[name]?.port {
                        Text(":\(String(port))").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

struct InferenceView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: Binding(get: { store.prompt }, set: { store.prompt = $0 }))
                .frame(height: 80)
            Button(store.busy ? "推理中…" : "发送（qwen3-4b · OpenAI 协议）") { store.sendPrompt() }
                .disabled(store.busy)
            ScrollView {
                Text(store.reply.isEmpty ? "回复将显示在这里" : store.reply)
                    .foregroundColor(store.reply.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }
}

struct MainWindowView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { store.tab }, set: { store.tab = $0 })) {
                Text("总览").tag(0)
                Text("模型服务").tag(1)
                Text("模型池").tag(2)
                Text("监控台").tag(3)
                Text("本地推理").tag(4)
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            switch store.tab {
            case 0: OverviewView(store: store)
            case 1: ServicesView(store: store)
            case 2: PoolsView(store: store)
            case 3: MonitorView(store: store)
            default: InferenceView(store: store)
            }
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

// ─── 模型池页 ──────────────────────────────────────────────────

struct PoolsView: View {
    @ObservedObject var store: GatewayStore

    var body: some View {
        VStack(spacing: 0) {
            if !store.actionMessage.isEmpty {
                Text(store.actionMessage)
                    .font(.callout)
                    .padding(8).frame(maxWidth: .infinity)
                    .background(Color.blue.opacity(0.08))
            }
            List {
                ForEach(store.models, id: \.name) { m in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(m.active == true ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(m.name).font(.body.weight(.medium))
                                Text(m.model_type ?? "llm").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                                Text(m.mode ?? "").font(.caption2).foregroundColor(.secondary)
                            }
                            Text(m.description ?? "")
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if m.active == true {
                            Button("停止") { store.stopService(m.name) }
                                .controlSize(.small)
                        } else {
                            Button("切换到此模型") { store.switchModel(m.name) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Text("pool 树状视图（iff/<pool> 候选链）将在接入 /admin/model-pools 后补全")
                .font(.caption2).foregroundColor(.secondary).padding(6)
        }
    }
}

// ─── 监控台页 ──────────────────────────────────────────────────

struct MonitorView: View {
    @ObservedObject var store: GatewayStore

    private var totalRequests: Int { store.curve.reduce(0) { $0 + $1.requests } }
    private var totalTokens: Int { store.curve.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                StatTile(title: "24h 请求", value: "\(totalRequests)")
                StatTile(title: "24h Tokens", value: "\(totalTokens)")
                StatTile(title: "网关状态", value: store.gatewayUp ? "在线 :8999" : "离线")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("每小时请求数（近 24h）").font(.subheadline).foregroundColor(.secondary)
                if store.curve.isEmpty {
                    Text("暂无数据 — 发起一次对话后这里会出现曲线")
                        .foregroundColor(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart(store.curve, id: \.t) { p in
                        BarMark(
                            x: .value("时间", Date(timeIntervalSince1970: p.t)),
                            y: .value("请求", p.requests)
                        )
                        .foregroundStyle(Color.blue.opacity(0.7))
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 140)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

// ─── AppKit 引导：菜单栏常驻 + 主窗口 ───────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = GatewayStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenuBarItem()
        showOverview()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // 关窗后菜单栏常驻
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
        let quit = NSMenuItem(title: "退出 MacFabric", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func showOverview() {
        if window == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
            win.title = "MacFabric"
            win.center()
            win.delegate = self
            window = win
        }
        window?.contentView = NSHostingView(rootView: MainWindowView(store: store))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDashboard() {
        if let url = URL(string: "http://127.0.0.1:8999/") { NSWorkspace.shared.open(url) }
    }
}

// ─── main（无 @main 宏，直接引导）────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
