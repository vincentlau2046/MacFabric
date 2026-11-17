// 模型详情栏（UI v2：280pt 并行或 <1450px 覆盖层）
// 官方真名作标题；内部 pack/实例 ID 退到技术详情；调用 ID 用 SF Mono 可复制。
// 消费完整资料（ModelTableRow + 扩展字段），不读硬编码模板白名单。
import SwiftUI

struct ModelDetailField: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let mono: Bool
    var copyable: Bool = false
    var multiline: Bool = false
    init(_ label: String, _ value: String, mono: Bool = false, copyable: Bool = false, multiline: Bool = false) {
        self.label = label; self.value = value; self.mono = mono; self.copyable = copyable; self.multiline = multiline
    }
}

struct ModelDetails: View {
    let row: ModelTableRow
    var fields: [ModelDetailField] = []       // 页面特定扩展（端口/策略/路径等）
    var autostart: Binding<Bool>? = nil
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let onClose {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.faint)
                        }.buttonStyle(.plain).accessibilityIdentifier("model-details-close")
                    }
                }
                // 官方模型真名 + 类型；回退名诚实标注
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.ink)
                    HStack(spacing: 6) {
                        Capsule().fill(DS.threadColor(row.type)).frame(width: 14, height: 4)
                        Text(row.type.displayName).font(.system(size: 12)).foregroundColor(.dim)
                        if row.titleIsFallback {
                            Text("· 资料待补全").font(.system(size: 11)).foregroundColor(.faint)
                        }
                    }
                }
                // 运行状态
                if let rs = row.runState {
                    HStack(spacing: 6) {
                        Circle().fill(rs == .available ? DS.okC : (rs == .error ? DS.errC : DS.warnC))
                            .frame(width: 8, height: 8)
                        Text(rs.label).font(.system(size: 12.5)).foregroundColor(.ink)
                        if let mem = row.memoryText {
                            Text("· \(mem)").font(DS.monoDigit(.system(size: 12))).foregroundColor(.dim)
                        }
                    }
                }
                // 全部能力标签（表格只显示两个，详情给全）
                if !row.capabilities.isEmpty {
                    detailSection("能力") {
                        FlowTags(tags: row.capabilities.map(\.label))
                    }
                }
                // 技术详情：调用 ID / 实例 ID / 包 ID …
                detailSection("技术详情") {
                    idField("调用 ID", row.target.apiModelID)
                    idField("实例 ID", row.target.instanceID)
                    if let pack = row.target.packID {
                        idField("能力包", pack)
                    }
                    ForEach(fields) { f in
                        idField(f.label, f.value, mono: f.mono, copyable: f.copyable)
                    }
                }
                // 显式加载策略（已有策略展示真实值；无策略不假装默认值）
                if let autostart {
                    Toggle("随网关自动加载", isOn: autostart)
                        .font(.system(size: 12.5)).foregroundColor(.ink)
                        .toggleStyle(.switch).controlSize(.small)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.panel)
    }

    @ViewBuilder private func idField(_ label: String, _ value: String, mono: Bool = true, copyable: Bool = true, multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(.faint).frame(width: 56, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? DS.mono(11) : .system(size: 11)).foregroundColor(.dim)
                .lineLimit(multiline ? nil : 1)
                .truncationMode(multiline ? .tail : .middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if copyable, !value.isEmpty {
                CopyButton("复制", text: value, small: true)
            }
        }
    }

    @ViewBuilder private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        // 原生检查器风格：分区之间用发丝分隔线，不做卡片底色
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.lineC)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.faint)
            content()
        }
    }
}

/// 简单流式标签（详情内全量能力）
struct FlowTags: View {
    let tags: [String]
    var body: some View {
        FlexibleFlow(items: tags) { tag in
            Text(tag).font(.system(size: 10.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(DS.chrome).cornerRadius(DS.Radius.chip)
                .foregroundColor(.dim)
        }
    }
}

/// 轻量流式布局（CLT 无 SwiftUI 布局宏；用 AlignmentGuide 方案）
struct FlexibleFlow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        // 能力标签数量有限（≤8），简单 HStack 折行即可：两行内的场景占绝大多数
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(chunked(items, 3)), id: \.self) { chunk in
                HStack(spacing: 4) { ForEach(chunk, id: \.self) { content($0) } }
            }
        }
    }
    private func chunked(_ arr: [Item], _ size: Int) -> [[Item]] {
        guard !arr.isEmpty else { return [] }
        return stride(from: 0, to: arr.count, by: size).map { Array(arr[$0..<Swift.min($0 + size, arr.count)]) }
    }
}
