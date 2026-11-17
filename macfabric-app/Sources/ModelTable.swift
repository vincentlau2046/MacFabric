// 共享模型表格 — Apple 原生设计语言（用户裁决 2026-11-16：用原生，不用 CSS 式自绘）
// SwiftUI Table（macOS NSTableView 底座）：原生列头/选中/行分隔/键盘导航。
// 列的取舍仍由 ModelColumnLayout 断点决定（契约测试钉住）；宽度由页面实测传入。
// 样稿对应：本地推理=模型/类型/能力/运行状态/内存基线/操作；
//          模型服务=模型/类型/来源/可用状态/接入；能力包=模型/类型/能力/变体/体积/兼容/验证/安装/操作。
import SwiftUI

// ── 行模型（视图层；纯数据在 ProductModels.swift）───────────────

struct ModelTableAction: Identifiable {
    let id = UUID()
    let label: String
    let primary: Bool
    var disabled: Bool = false
    let perform: () -> Void
    init(label: String, primary: Bool = false, disabled: Bool = false, perform: @escaping () -> Void) {
        self.label = label; self.primary = primary; self.disabled = disabled; self.perform = perform
    }
}

struct ModelTableRow: Identifiable {
    let id: String                       // instanceID 或 packID|variant — 永不 displayName
    let title: String                    // 官方模型真名；回退时展示 instanceID
    let titleIsFallback: Bool
    let subtitle: String?                // 名称下的能力副标（样稿：中文 / 对话）
    let type: PrimaryType
    let capabilities: [CapabilityTag]
    let runState: RunState?
    let statusText: String?
    let memoryText: String?
    let sourceText: String?
    let target: ModelActionTarget
    let actions: [ModelTableAction]
    var variantText: String? = nil
    var sizeText: String? = nil
    var compatText: String? = nil
    var verificationText: String? = nil
    var installText: String? = nil

    init(id: String, title: String?, type: PrimaryType, capabilities: [CapabilityTag] = [],
         subtitle: String? = nil,
         runState: RunState? = nil, statusText: String? = nil, memoryText: String? = nil,
         sourceText: String? = nil, target: ModelActionTarget,
         actions: [ModelTableAction] = [],
         variantText: String? = nil, sizeText: String? = nil, compatText: String? = nil,
         verificationText: String? = nil, installText: String? = nil) {
        let fallback = title == nil || title!.isEmpty
        self.id = id
        self.title = fallback ? id : title!
        self.titleIsFallback = fallback
        self.subtitle = subtitle
        self.type = type
        self.capabilities = capabilities
        self.runState = runState
        self.statusText = statusText
        self.memoryText = memoryText
        self.sourceText = sourceText
        self.target = target
        self.actions = actions
        self.variantText = variantText
        self.sizeText = sizeText
        self.compatText = compatText
        self.verificationText = verificationText
        self.installText = installText
    }
}

// ── 页面宽度测量（背景式，不影响布局）───────────────────────────

struct ContentWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct WidthReader: View {
    let key: String
    var store: GatewayStore
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ContentWidthKey.self, value: [key: geo.size.width])
        }
        .onPreferenceChange(ContentWidthKey.self) { dict in
            if let w = dict[key], abs(w - (store.contentWidths[key] ?? 0)) > 1 {
                store.contentWidths[key] = w
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// ── 原生表格 ───────────────────────────────────────────────────

struct ModelTable: View {
    let page: ModelColumnLayout.Page
    let rows: [ModelTableRow]
    var selectedID: String?
    var onSelect: ((String) -> Void)?
    var availableWidth: CGFloat = 900

    var body: some View {
        let cols = ModelColumnLayout.visibleColumns(page: page, availableWidth: availableWidth)
        Table(rows, selection: selectionBinding) {
            if cols.contains(.name) { nameColumn }
            if cols.contains(.type) { typeColumn }
            if cols.contains(.capabilities) { capsColumn }
            if cols.contains(.source) { sourceColumn }
            if cols.contains(.status) { statusColumn }
            if cols.contains(.memory) { memoryColumn }
            if cols.contains(.variant) || cols.contains(.size) {
                if cols.contains(.variant) { TableColumn("变体") { r in monoCell(r.variantText) }.width(72) }
                if cols.contains(.size) { TableColumn("下载体积") { r in monoCell(r.sizeText) }.width(80) }
            }
            if cols.contains(.compat) || cols.contains(.verification) {
                if cols.contains(.compat) { TableColumn("兼容性") { r in compatCell(r) }.width(64) }
                if cols.contains(.verification) { TableColumn("验证") { r in verifyCell(r) }.width(64) }
            }
            if cols.contains(.install) { TableColumn("安装状态") { r in plainCell(r.installText) }.width(80) }
            if cols.contains(.actions) { actionColumn }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("查看详情") { onSelect?(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { onSelect?(id) }   // 双击行 → 详情
        }
        .tableStyle(.inset)   // 原生内嵌风格（现代 Finder 观感：圆角容器、无竖向列分隔）
    }

    // 原生 Table 选中（Set 桥接单选）
    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { Set([selectedID].compactMap { $0 }) },
                set: { ids in
                    if let id = ids.first { onSelect?(id) } else { onSelect?("") }
                })
    }

    // ── 列（原生样式；内容即视图）────────────────────────────
    // 名称列：单行等高（用户裁决 2026-11-17：不因"看图"副标造成行高不齐）。
    // 看图能力 = 名称前小图标（全 fabric 统一口径：CapabilityTag id "vision"）；
    // "资料待补全"说明退详情栏，不在表格里撑行高。
    private var nameColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn("模型名称") { r in
            HStack(spacing: 5) {
                if r.capabilities.contains(where: { $0.id == "vision" || $0.label == "看图" }) {
                    Image(systemName: "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("支持看图（VL）")
                }
                Text(r.title).lineLimit(1)
            }
        }
    }
    private var typeColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn("类型") { r in
            Label(r.type.displayName, systemImage: typeIcon(r.type))
        }
        .width(min: 96, ideal: 110)
    }
    private var capsColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn("能力") { r in
            // 主标签在前 + 至多 2 修饰（#45 呈现规则；上限在 CapabilityTags 出口已保证，此处兜底）
            Text(r.capabilities.prefix(3).map { tag in tag.label }.joined(separator: " / "))
                .foregroundStyle(.secondary)
        }
        .width(min: 90, ideal: 150)
    }
    private var sourceColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn("来源") { r in
            Text(r.sourceText ?? "本地模型").foregroundStyle(.secondary)
        }
        .width(min: 80, ideal: 120)
    }
    private var statusColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn(page == .hub ? "可用状态" : "运行状态") { r in
            if let rs = r.runState {
                Label {
                    Text(page == .hub && rs == .notLoaded ? "按需可用" : rs.label)
                } icon: {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(stateColor(rs))
                        .font(.system(size: 7))
                }
            } else if let s = r.statusText {
                Text(s).foregroundStyle(.secondary)
            }
        }
        .width(min: 84, ideal: 100)
    }
    private var memoryColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn("内存基线") { r in
            Text(r.memoryText ?? "未知").monospacedDigit()
                .foregroundStyle(r.memoryText == nil ? .secondary : .primary)
        }
        .width(min: 76, ideal: 92)
    }
    private var actionColumn: some TableColumnContent<ModelTableRow, Never> {
        TableColumn("操作") { r in
            if let first = r.actions.first {
                Button(first.label) { first.perform() }
                    .disabled(first.disabled)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .width(min: 68, ideal: 84)
    }

    // ── 小单元 ──────────────────────────────────────────────
    private func plainCell(_ s: String?) -> Text {
        Text(s ?? "—").foregroundStyle(s == nil ? .secondary : .primary)
    }
    private func monoCell(_ s: String?) -> Text {
        Text(s ?? "—").font(.system(size: 12, design: .monospaced))
            .foregroundStyle(s == nil ? .secondary : .primary)
    }
    private func compatCell(_ r: ModelTableRow) -> Text {
        // 兼容性：可安装 / 需适配（样稿用词；待接入 = 模板未实现）
        switch r.compatText {
        case "待接入": Text("待接入").foregroundStyle(.secondary)
        case nil: Text("—").foregroundStyle(.secondary)
        default: Text("可安装").foregroundStyle(.green)
        }
    }
    private func verifyCell(_ r: ModelTableRow) -> Text {
        // 诚实验证列：无真实验证记录时显示“待验证”，绝不冒充
        Text(r.verificationText ?? "待验证")
            .foregroundStyle(r.verificationText == nil ? Color.secondary : Color.green)
    }

    private func typeIcon(_ t: PrimaryType) -> String {
        switch t {
        case .llm: "text.bubble"
        case .vl: "eye"
        case .embedding: "square.stack.3d.down.left"
        case .rerank: "arrow.up.arrow.down"
        case .asr: "waveform"
        case .tts: "speaker.wave.2"
        case .ocr: "doc.text.viewfinder"
        case .aigc: "photo"
        case .unknown: "questionmark.circle"
        }
    }
    private func stateColor(_ s: RunState) -> Color {
        switch s {
        case .available: .green
        case .loading, .sleeping: .orange
        case .error: .red
        case .notLoaded: .gray
        }
    }
}
