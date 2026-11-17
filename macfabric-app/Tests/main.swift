// 产品契约测试（scripts/test-app-contracts.sh 编译执行）
// 覆盖 UI v2 合同的可判定规则：身份不得由 slug 猜测、未知类型不得默认对话、
// 列断点、按能力端点示例、密钥占位符、预算单次扣减、鉴权未知≠关闭。
// 每个用例失败即打印 FAIL 并置 exit 1。
import Foundation

var failures: [String] = []
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { print("PASS: \(name)") } else { failures.append(name + (detail.isEmpty ? "" : " — \(detail)")) }
}

// 1. 未知类型不得默认“对话”
check("unknownTypeNotChat", PrimaryType.from(raw: "robot") == .unknown && PrimaryType.from(raw: nil) == .unknown && PrimaryType.unknown.displayName == "未知类型")
check("knownTypeNames", PrimaryType.llm.displayName == "文本生成" && PrimaryType.embedding.displayName == "文本嵌入" && PrimaryType.rerank.displayName == "相关性重排" && PrimaryType.vl.displayName == "视觉理解" && PrimaryType.aigc.displayName == "图像生成")

// 2. 显示名不得由 pack- 前缀反推；回退必须诚实标注
let fallback = ProductIdentity(instanceID: "pack-bge-m3-1-0-0", displayName: nil, apiModelID: "bge-m3", packID: "embedding.bge-m3")
check("nameNotDerivedFromSlug", fallback.displayName == "pack-bge-m3-1-0-0" && fallback.displayNameIsFallback,
      "got \(fallback.displayName)")
let explicit = ProductIdentity(instanceID: "pack-bge-m3-1-0-0", displayName: "BGE-M3", apiModelID: "bge-m3", packID: "embedding.bge-m3")
check("explicitNameKept", explicit.displayName == "BGE-M3" && !explicit.displayNameIsFallback)

// 3. 同名实例身份独立
let a = ProductModel(id: "inst-a", displayName: "同名模型", type: .llm, active: true)
let b = ProductModel(id: "inst-b", displayName: "同名模型", type: .llm, active: true)
check("duplicateNamesKeepInstanceIdentity", a.id != b.id && a.displayName == b.displayName)

// 4. 未知资源显示“未知”，不是 0
check("resourceNilNotZero", MemoryMath.baselineText(mb: nil) == "未知" && MemoryMath.baselineText(mb: 2150) == "约 2.1 GiB")

// 5. 列断点（UI v2 §3：W≥1100 完整；820..1099 收能力列；<820 再收资源列）
let full = ModelColumnLayout.visibleColumns(page: .localInference, availableWidth: 1100)
let mid = ModelColumnLayout.visibleColumns(page: .localInference, availableWidth: 1099)
let tight = ModelColumnLayout.visibleColumns(page: .localInference, availableWidth: 819)
check("columnsFullAt1100", full.contains(.capabilities) && full.contains(.memory) && full.first == .name && full.last == .actions)
check("columnsDropCapabilitiesAt1099", !mid.contains(.capabilities) && mid.contains(.memory))
check("columnsDropMemoryAt819", !tight.contains(.memory) && !tight.contains(.capabilities))
check("columnsCoreAlwaysPresent", tight.contains(.name) && tight.contains(.type) && tight.contains(.status) && tight.contains(.actions))
let catMid = ModelColumnLayout.visibleColumns(page: .catalog, availableWidth: 1099)
check("catalogMidDropsVariantSizeVerification", !catMid.contains(.variant) && !catMid.contains(.size) && !catMid.contains(.verification) && catMid.contains(.compat))

// 6. 按能力端点：嵌入不走聊天
check("embeddingEndpoint", APIExamples.endpoint(for: .embedding) == "/v1/embeddings" && APIExamples.endpoint(for: .rerank) == "/v1/rerank" && APIExamples.endpoint(for: .aigc) == "/v1/images/generations")
check("unknownTypeNoEndpoint", APIExamples.endpoint(for: .unknown) == nil)
let emb = APIExamples.make(modelID: "bge-m3", type: .embedding, baseURL: "http://127.0.0.1:8999", format: .curl) ?? ""
check("embeddingExampleNotChat", emb.contains("/v1/embeddings") && emb.contains("input") && !emb.contains("messages") && !emb.contains("ANTHROPIC"))
check("rerankExampleQueryDocuments", (APIExamples.make(modelID: "bge-reranker-v2-m3", type: .rerank, baseURL: "http://127.0.0.1:8999", format: .curl) ?? "").contains("\"query\"") && APIExamples.make(modelID: "x", type: .rerank, baseURL: "http://x", format: .curl)!.contains("\"documents\""))

// 7. 示例只用占位符，绝不出现真实凭证或“未启用鉴权”
check("examplesNeverContainCredential", !emb.contains("sk-") && !emb.contains("未启用鉴权") && emb.contains(APIExamples.envPlaceholder))
let jsonCfg = APIExamples.make(modelID: "qwen3-4b-instruct-2507", type: .llm, baseURL: "http://127.0.0.1:8999", format: .json) ?? ""
check("jsonUsesPlaceholder", jsonCfg.contains(APIExamples.credentialPlaceholder))

// 8. 无活跃 LLM 时试聊目标为 nil — 绝不回退到嵌入/首个模型
let embOnly = ProductModel(id: "e1", displayName: "BGE-M3", type: .embedding, active: true)
let llmIdle = ProductModel(id: "l1", displayName: "Qwen3-4B-Instruct-2507", type: .llm, active: false)
check("noLLMDoesNotFallback", TryoutPolicy.pickChatTarget([embOnly]) == nil && TryoutPolicy.pickChatTarget([embOnly, llmIdle]) == nil)
let llmActive = ProductModel(id: "l2", displayName: "Qwen3-4B-Instruct-2507", type: .llm, active: true)
check("activeLLMPicked", TryoutPolicy.pickChatTarget([embOnly, llmActive])?.id == "l2")

// 9. 预算只扣一次 reserve（QA 口径：36G−8G=28G）
check("budgetSubtractsReserveOnce", MemoryMath.freeBudgetMB(total: 36864, used: 0, reserve: 8192) == 28672)
check("budgetWithUsed", MemoryMath.freeBudgetMB(total: 36864, used: 8192, reserve: 8192) == 20480)
check("budgetFloorsAtZero", MemoryMath.freeBudgetMB(total: 4096, used: 8192, reserve: 8192) == 0)

// 10. 鉴权：网关不可达/未加载 ≠ 未启用
check("authDownIsUnknown", AuthPresentation.present(policy: "all", gatewayUp: false, fetched: false) == .unknown)
check("authAllEnabled", AuthPresentation.present(policy: "all", gatewayUp: true, fetched: true) == .enabledAll)
check("authPools", AuthPresentation.present(policy: "pools", gatewayUp: true, fetched: true) == .enabledPools)
check("authOffDisabled", AuthPresentation.present(policy: "off", gatewayUp: true, fetched: true) == .disabled)
check("authNilPolicyUnknown", AuthPresentation.present(policy: nil, gatewayUp: true, fetched: true) == .unknown)
check("authTextHonest", AuthPresentation.text(for: .unknown) == "状态未知" && AuthPresentation.text(for: .enabledAll) == "已启用 · 全部请求")

// 11. 监控行身份：同名不同实例不合并
check("monitorRowsNotMergedByName", MonitorIdentity.key(location: "local", provider: "-", model: "glm-5") != MonitorIdentity.key(location: "cloud", provider: "AtlasWork", model: "glm-5"))

// 12. 调用 ID 规范（本地）：小写连字符、保留前缀拒绝
check("apiModelIDValidation", APIIdentity.validate("bge-m3") != nil && APIIdentity.validate("BGE-M3") == nil && APIIdentity.validate("pack-x") == nil && APIIdentity.validate("fabric-flash") == nil && APIIdentity.validate("-x") == nil && APIIdentity.validate("x-") == nil && APIIdentity.validate("q--x") == nil && APIIdentity.validate("qwen3-4b-instruct-2507") != nil)

// 13. 固定 fixture 解码（A2 DTO 同源合同）：蛇形字段、未知类型/资源、云端来源、重复名变体
let fixtureURL = URL(fileURLWithPath: "macfabric-app/Tests/Fixtures/product-models.json")
let fixtureModels: [ProductModel] = {
    guard let data = try? Data(contentsOf: fixtureURL) else { return [] }
    return (try? JSONDecoder().decode([ProductModel].self, from: data)) ?? []
}()
check("fixtureDecodes", fixtureModels.count == 9, "decoded \(fixtureModels.count)")
let fBge = fixtureModels.first { $0.id == "pack-bge-m3-1-0-0" }
check("fixtureIdentityTriplet", fBge?.displayName == "BGE-M3" && fBge?.id == "pack-bge-m3-1-0-0" && fBge?.apiModelID == "bge-m3")
let fUnknown = fixtureModels.first { $0.id == "inst-unknown-type" }
check("fixtureUnknownHonest", fUnknown?.type == .unknown && fUnknown?.displayName == "inst-unknown-type" && fUnknown?.displayNameIsFallback == true && fUnknown?.memoryBaselineMB == nil)
let fCloud = fixtureModels.first { $0.id == "cloud-glm-5" }
check("fixtureCloudKeptUpstreamID", fCloud?.apiModelID == "glm-5" && fCloud?.source == .cloud(provider: "AtlasWork"))
let fDupes = fixtureModels.filter { $0.displayName == "BGE-M3" }
check("fixtureDuplicateNamesDistinctIDs", fDupes.count == 2 && fDupes[0].id != fDupes[1].id && fDupes[0].variant != fDupes[1].variant)
let fFail = fixtureModels.first { $0.id == "pack-bge-reranker-v2-m3-0-1-0" }
check("fixtureHealthErrorShown", fFail?.runState == .error)

// 14. 鉴权状态机：HTTP 5xx/畸形/超时 ≠ 未启用；lastGood 标 stale；旧代际响应忽略
let okJSON = #"{"policy":"all","active":true,"enforced":true}"#.data(using: .utf8)!
let okResp = HTTPURLResponse(url: URL(string: "http://127.0.0.1:8999/admin/security/status")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
let bad500 = HTTPURLResponse(url: okResp.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
var store = SecurityStatusStore()
check("initialLoading", store.state == .loading)
store.apply(1, .success(SecurityGatewayStatus.parse(data: okJSON, response: okResp, error: nil)!))
check("loadedAllFrom200", store.state == .loaded(SecuritySnapshot(policy: "all", active: true, enforced: true, fetchedAt: store.snapshot?.fetchedAt ?? Date.distantPast), stale: false))
store.apply(2, .failure(StatusFetchError.http(500)))
check("lastGoodMarkedStale", store.state == .loaded(store.snapshot ?? SecuritySnapshot(policy: "x", active: false, enforced: false, fetchedAt: .distantPast), stale: true), "state=\(store.state)")
var fresh = SecurityStatusStore()
fresh.apply(1, .failure(StatusFetchError.http(500)))
check("http500NotDisabled", fresh.state == .unavailable, "state=\(fresh.state)")
fresh.apply(2, .failure(StatusFetchError.timeout))
check("timeoutNotDisabled", fresh.state == .unavailable)
fresh.apply(3, .failure(StatusFetchError.malformed))
check("malformedNotDisabled", fresh.state == .unavailable)
var genStore = SecurityStatusStore()
genStore.apply(5, .success(SecurityGatewayStatus.parse(data: okJSON, response: okResp, error: nil)!))
genStore.apply(4, .failure(StatusFetchError.http(500)))
check("oldGenerationIgnored", genStore.state == .loaded(SecuritySnapshot(policy: "all", active: true, enforced: true, fetchedAt: genStore.snapshot?.fetchedAt ?? .distantPast), stale: false))

// 15. 凭据存取：profile 隔离账目；保存失败绝不报“已保存”
final class RecordingStore: GatewayCredentialStore {
    var accounts: [String] = []
    var throwOnSave = false
    func load(profile: GatewayProfile) throws -> String? { nil }
    func save(_ key: String, profile: GatewayProfile) throws {
        accounts.append(profile.keychainAccount)
        if throwOnSave { throw CredentialStoreError.denied }
    }
    func delete(profile: GatewayProfile) throws {}
}
var rec = RecordingStore()
_ = try? rec.save("k", profile: .dev)
_ = try? rec.save("k", profile: .prod)
check("profileAccountsIsolated", rec.accounts.count == 2 && Set(rec.accounts) == ["dev|http://127.0.0.1:8998", "prod|http://127.0.0.1:8999"], "got \(rec.accounts)")
var denying = RecordingStore()
denying.throwOnSave = true
let outcome = CredentialFlow.record(store: denying, profile: .dev, key: "k")
check("keychainDeniedNotSaved", outcome == .failed("denied"), "got \(outcome)")
let okStore = RecordingStore()
check("saveSuccessHonest", CredentialFlow.record(store: okStore, profile: .dev, key: "k") == .saved)

// 16. 请求注入：仅匹配档位的推理 origin 注 Bearer；管理/下载/跨源不注；跨源重定向丢弃
let authReq = URLRequest(url: URL(string: "http://127.0.0.1:8998/v1/chat/completions")!)
let authorized = try InferenceRequestAuthorizer.authorize(authReq, profile: .dev, key: "SECRET")
check("authorizeInferenceOnly", authorized.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET")
let adminReq = URLRequest(url: URL(string: "http://127.0.0.1:8998/admin/security/status")!)
check("adminNoInjection", (try? InferenceRequestAuthorizer.authorize(adminReq, profile: .dev, key: "SECRET"))?.value(forHTTPHeaderField: "Authorization") == nil)
let wrongPort = URLRequest(url: URL(string: "http://127.0.0.1:8999/v1/chat/completions")!)
check("crossProfileRejected", (try? InferenceRequestAuthorizer.authorize(wrongPort, profile: .dev, key: "SECRET")) == nil)
check("redirectSameOriginOK", InferenceRequestAuthorizer.redirectAllowed(from: URL(string: "http://127.0.0.1:8998/v1/x")!, to: URL(string: "http://127.0.0.1:8998/v1/y")!, profile: .dev))
check("redirectCrossOriginDropped", !InferenceRequestAuthorizer.redirectAllowed(from: URL(string: "http://127.0.0.1:8998/v1/x")!, to: URL(string: "http://example.com/v1/y")!, profile: .dev))

// 17. 操作目标三分（B3）：启停用 instanceID、推理用 apiModelID、安装卸载用 packID
let packModel = ProductModel(id: "inst-9", displayName: "BGE-M3", type: .embedding,
                             apiModelID: "bge-m3", packID: "embedding.bge-m3")
let t = packModel.actionTarget
check("actionTargetTriplet", t.instanceID == "inst-9" && t.apiModelID == "bge-m3" && t.packID == "embedding.bge-m3")
let imported = ProductModel(id: "inst-10", displayName: "自导入", type: .llm, apiModelID: "my-llm")
check("importedTargetNoPack", imported.actionTarget.packID == nil)

// 18. 排序/过滤保 ID：筛选与排序不改变实例身份集合
let list = [packModel, imported,
            ProductModel(id: "inst-11", displayName: "Qwen3-4B-Instruct-2507", type: .llm, apiModelID: "q", active: true)]
let filtered = ModelListLogic.apply(list, query: "qwen", typeFilter: .llm)
check("filterPreservesIDs", filtered.map(\.id) == ["inst-11"])
let sorted = ModelListLogic.apply(list, query: "", typeFilter: nil)
check("sortStableIdentity", Set(sorted.map(\.id)) == Set(list.map(\.id)) && sorted.map(\.id).count == sorted.count)
let activeFirst = ModelListLogic.apply(list, query: "", typeFilter: nil)
check("activeFirstSort", activeFirst.first?.id == "inst-11")

// 19. 刷新保持选中：选中项仍在列表则保留，被移除才清空
var sel = SelectionKeeper()
sel.selectedID = "inst-10"
sel.refresh(availableIDs: ["inst-9", "inst-10", "inst-11"])
check("selectionKeptAcrossRefresh", sel.selectedID == "inst-10")
sel.refresh(availableIDs: ["inst-9", "inst-11"])
check("selectionClearedWhenRemoved", sel.selectedID == nil)

// 20. 运行态与安装态独立：已装可未加载、可活跃但非包管理
let installedIdle = ProductModel(id: "i1", displayName: "X", type: .llm, packID: "p.x")
check("installedNotRunning", installedIdle.actionTarget.packID != nil && !installedIdle.active)
let runningNoPack = ProductModel(id: "i2", displayName: "Y", type: .llm, active: true)
check("runningNotPackManaged", runningNoPack.active && runningNoPack.actionTarget.packID == nil)

// 21. 能力包标签统一（#45，spec 2026-11-17）：主标签由 capability 映射；修饰标签已知词映射/未知词透传
struct PackTagCase: Decodable {
    let name: String; let capability: String; let tags: [String]
}
let packCases: [PackTagCase] = {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: "macfabric-app/Tests/Fixtures/pack-tags.json")) else { return [] }
    return (try? JSONDecoder().decode([PackTagCase].self, from: data)) ?? []
}()
func capText(_ tags: [CapabilityTag]) -> String { tags.map(\.label).joined(separator: " / ") }
check("packTagFixtureLoads", packCases.count == 6, "loaded \(packCases.count)")

let llmFull = packCases.first { $0.name == "llm-full" }
let llmTags = CapabilityTags.displayTags(capability: llmFull?.capability ?? "", tags: llmFull?.tags ?? [])
check("packPrimaryFromCapability", llmTags.first == CapabilityTag(id: "llm", label: "对话"), "got \(llmTags.first.map { "\($0.id)|\($0.label)" } ?? "nil")")
check("packModifierMapped", capText(llmTags).contains("工具调用") && capText(llmTags).contains("多语"), "got \(capText(llmTags))")
check("packRawTagNotShown", !capText(llmTags).contains("chat") && !capText(llmTags).contains("multilingual"), "got \(capText(llmTags))")

let unk = packCases.first { $0.name == "unknown-tag" }
check("unknownTagPassthrough", capText(CapabilityTags.displayTags(capability: unk?.capability ?? "", tags: unk?.tags ?? [])).contains("future-cap"))

let cust = packCases.first { $0.name == "custom" }
check("customTagMapped", capText(CapabilityTags.displayTags(capability: cust?.capability ?? "", tags: cust?.tags ?? [])).contains("自定义"))

let vlCase = packCases.first { $0.name == "vl" }
let vlTags = CapabilityTags.displayTags(capability: vlCase?.capability ?? "", tags: vlCase?.tags ?? [])
check("visionPrimaryAnchored", vlTags.first == CapabilityTag(id: "vision", label: "看图"), "got \(vlTags.first.map { "\($0.id)|\($0.label)" } ?? "nil")")

let empty = packCases.first { $0.name == "empty-tags" }
check("noVisionSynthesized", !CapabilityTags.displayTags(capability: empty?.capability ?? "", tags: empty?.tags ?? [])
    .contains(where: { $0.id == "vision" || $0.label == "看图" }))

let capped = packCases.first { $0.name == "modifier-cap" }
let cappedTags = CapabilityTags.displayTags(capability: capped?.capability ?? "", tags: capped?.tags ?? [])
check("modifiersCappedAtTwo", cappedTags.count == 3 && capText(cappedTags) == "对话 / 工具调用 / 多语", "got \(capText(cappedTags))")
let fullDetail = CapabilityTags.displayTags(capability: capped?.capability ?? "", tags: capped?.tags ?? [], modifierLimit: .max)
check("detailShowsAllTags", fullDetail.count == 5, "got \(fullDetail.count)")

// 22. 看图三态呈现（沿用网关 model_specs 口径；禁 bool() 塌缩 — spec 语义红线 2）
check("visionTriState", VisionPresentation.showsTag(supportsVision: true)
    && !VisionPresentation.showsTag(supportsVision: nil) && !VisionPresentation.showsTag(supportsVision: false))
check("visionDetailHonest", VisionPresentation.detailText(supportsVision: false) == "不支持"
    && VisionPresentation.detailText(supportsVision: nil) == nil && VisionPresentation.detailText(supportsVision: true) == nil)

// 23. 网关守护（设置页"开机时启动网关"，spec 2026-11-17-gateway-daemon-toggle.md）
check("daemonStateNotInstalled", GatewayDaemon.state(plistExists: false, launchctlPrint: nil) == .notInstalled)
check("daemonStateStopped", GatewayDaemon.state(plistExists: true, launchctlPrint: nil) == .stopped
    && GatewayDaemon.state(plistExists: true, launchctlPrint: "state = waiting\nprogram = x") == .stopped)
check("daemonStateRunning", GatewayDaemon.state(plistExists: true, launchctlPrint: "state = running\npid = 10978") == .running(pid: "10978"))
let xml = GatewayDaemon.plistXML(prodDir: "/Users/x/Library/MacFabric/prod",
                                 modelsDir: "/Users/x/.inferfabric/models.d",
                                 logPath: "/Users/x/.inferfabric/logs/gateway.launchd.log",
                                 label: "com.macfabric.gateway")
check("daemonPlistTemplate", xml.contains("com.macfabric.gateway")
    && xml.contains("/Users/x/Library/MacFabric/prod/.venv/bin/python")
    && xml.contains("<string>-m</string>") && xml.contains("<string>inferfabric.proxy.handler</string>")
    && xml.contains("<key>RunAtLoad</key>") && xml.contains("<key>KeepAlive</key>")
    && xml.contains("WorkingDirectory") && xml.contains("macfabric_gateway")
    && xml.contains("/Users/x/.inferfabric/models.d")
    && xml.contains("/Users/x/.inferfabric/logs/gateway.launchd.log"))
check("daemonBootstrapArgs", GatewayDaemon.bootstrapArgs(uid: "501", plistPath: "/p/x.plist") == ["bootstrap", "gui/501", "/p/x.plist"])
check("daemonBootoutArgs", GatewayDaemon.bootoutArgs(uid: "501", label: "com.macfabric.gateway") == ["bootout", "gui/501/com.macfabric.gateway"])
check("daemonPrintArgs", GatewayDaemon.printArgs(uid: "501", label: "com.macfabric.gateway") == ["print", "gui/501/com.macfabric.gateway"])
let qaXML = GatewayDaemon.plistXML(prodDir: "/p", modelsDir: "/m", logPath: "/l", label: "com.macfabric.gateway.qa",
                                   programArgs: ["/bin/sleep", "3600"])
check("daemonPlistQAProgramOverride", qaXML.contains("<string>/bin/sleep</string>")
    && qaXML.contains("<string>3600</string>") && !qaXML.contains("inferfabric.proxy.handler"))


// 24. GatewayClient — 批 1 TOP2 统一网络层 + admin token 双账目 + born 迁移
// （spec docs/superpowers/specs/2026-11-17-batch1-auth-network-state.md）
final class MemoryAdminTokenStore: GatewayCredentialStore {
    var items: [String: String] = [:]
    var throwOnSave = false
    func load(profile: GatewayProfile) throws -> String? { items[profile.keychainAccount] }
    func save(_ key: String, profile: GatewayProfile) throws {
        if throwOnSave { throw CredentialStoreError.denied }
        items[profile.keychainAccount] = key
    }
    func delete(profile: GatewayProfile) throws { items.removeValue(forKey: profile.keychainAccount) }
}
check("adminServiceDiffersFromInference", AdminTokenCredentialStore.serviceName != GatewayProfile.keychainService
    && AdminTokenCredentialStore.serviceName == "io.macfabric.gateway-admin")

func fileReader(_ text: String?) -> (GatewayProfile) -> String? { { _ in text } }
var migrated = MemoryAdminTokenStore()
let m1 = AdminTokenBootstrap.migrate(store: migrated, fileReader: fileReader("MACFABRIC_ADMIN_TOKEN=born-tok-1\nOTHER=x"), profile: .dev)
check("bornMigrateReadsFileSavesKeychain", m1 == .migrated && migrated.items["dev|http://127.0.0.1:8998"] == "born-tok-1")
let m2 = AdminTokenBootstrap.migrate(store: migrated, fileReader: fileReader("MACFABRIC_ADMIN_TOKEN=born-tok-1\n"), profile: .dev)
check("bornMigrateIdempotentAlreadyStored", m2 == .alreadyStored)
let m3 = AdminTokenBootstrap.migrate(store: migrated, fileReader: fileReader(nil), profile: .prod)
check("bornMigrateAbsentHonest", m3 == .absent && migrated.items["prod|http://127.0.0.1:8999"] == nil)
var denyingStore = MemoryAdminTokenStore(); denyingStore.throwOnSave = true
let m4 = AdminTokenBootstrap.migrate(store: denyingStore, fileReader: fileReader("MACFABRIC_ADMIN_TOKEN=t"), profile: .dev)
check("bornMigrateDeniedHonest", m4 == .failed("denied"))

let adminAttachReq = URLRequest(url: URL(string: "http://127.0.0.1:8999/admin/cloud/providers")!)
let attached = AdminRequestAuthorizer.attach(adminAttachReq, profile: .prod, token: "tok-9")
check("adminAttachSameOrigin", attached.value(forHTTPHeaderField: "X-Admin-Token") == "tok-9")
let v1Req = URLRequest(url: URL(string: "http://127.0.0.1:8999/v1/chat/completions")!)
check("adminAttachSkipsInference", AdminRequestAuthorizer.attach(v1Req, profile: .prod, token: "tok-9").value(forHTTPHeaderField: "X-Admin-Token") == nil)
let crossReq = URLRequest(url: URL(string: "http://127.0.0.1:8998/admin/x")!)
check("adminAttachSkipsCrossProfile", (try? AdminRequestAuthorizer.authorize(crossReq, profile: .prod, token: "tok-9")) == nil)

check("clientErrorHttpMap", GatewayClientError.from(status: 401) == .unauthorized && GatewayClientError.from(status: 503) == .http(503))
var gen = GenerationGuard()
gen.bump()
gen.bump()
check("generationGuardOldDropped", gen.accept(1) == false && gen.accept(3) == true && gen.accept(2) == false)

// ── 批 1 语义修订：Admin 门禁默认关闭、配置即启用（用户裁决 2026-11-17）──
// attachAdminToken 的策略分支在 GatewayStore 私有，这里钉住策略契约：
// 默认（无环境变量）= 非严格模式，App 侧不拦截本机管理动作。
check("adminAuthPolicyDefaultOff", AdminAuthPolicy.strictMode == false)

// ── 批 3：SSE 解析 / 选模型 / 停止文案（spec 2026-11-17-batch3-stream-chat.md）──

check("sseDeltaContent", SSEParser.parse(line: "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}").delta == "Hello")
check("sseRoleFirstFrameNil", SSEParser.parse(line: "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}").delta == nil)
check("sseDoneFrame", SSEParser.parse(line: "data: [DONE]").done == true)
check("sseCommentIgnored", SSEParser.parse(line: ": keepalive").done == false && SSEParser.parse(line: ": keepalive").delta == nil)
check("sseMalformedFrameHonest", SSEParser.parse(line: "data: not-json").delta == nil && SSEParser.parse(line: "data: not-json").done == false)
check("sseUsageTailFrameNil", SSEParser.parse(line: "data: {\\").delta == nil)

check("chatTargetPreferredKept", ChatTargetPicker.pick(activeLLMs: ["a", "b"], preferred: "b") == "b")
check("chatTargetPreferredGoneFallback", ChatTargetPicker.pick(activeLLMs: ["a", "b"], preferred: "z") == "a")
check("chatTargetNoPreferredFirst", ChatTargetPicker.pick(activeLLMs: ["a", "b"], preferred: nil) == "a")
check("chatTargetEmptyNil", ChatTargetPicker.pick(activeLLMs: [], preferred: "a") == nil)

check("chatStopKeepsPartial", ChatStop.finalText("今天天气") == "今天天气\n\n（已停止 — 部分回复）")
check("chatStopEmptyHonest", ChatStop.finalText("") == "（已停止 — 未收到内容）")

// ── 批 4：job 轮询终态判定（spec 2026-11-17-batch4-jobs-infra.md）──

check("jobRunningKeepsPolling", JobCompletion.evaluate(["status": "running"], elapsed: 10, timeout: 300) == .keepPolling)
check("jobQueuedKeepsPolling", JobCompletion.evaluate(["status": "queued"], elapsed: 10, timeout: 300) == .keepPolling)
check("jobUnknownKeepsPolling", JobCompletion.evaluate(["status": "weird"], elapsed: 10, timeout: 300) == .keepPolling)
check("jobNilKeepsPolling", JobCompletion.evaluate(nil, elapsed: 10, timeout: 300) == .keepPolling)
check("jobDoneSucceeds", JobCompletion.evaluate(["status": "done"], elapsed: 400, timeout: 300) == .succeeded, "终态结果优先于超时")
check("jobFailedDetected", JobCompletion.evaluate(["status": "failed"], elapsed: 10, timeout: 300) == .failed)
check("jobCancelledDetected", JobCompletion.evaluate(["status": "cancelled"], elapsed: 10, timeout: 300) == .cancelled)
check("jobRunningTimesOut", JobCompletion.evaluate(["status": "running"], elapsed: 301, timeout: 300) == .timedOut, "App 停止轮询但不谎报失败")

// ── 汇总（文件末尾）：任何位置断言失败都能如实报告，杜绝“静默失败 + exit 0”盲区 ──
if failures.isEmpty {
    print("CONTRACT_TESTS_OK: 全部断言通过")
} else {
    print("CONTRACT_TESTS_FAILED: \(failures.count)")
    failures.forEach { print("  FAIL: \($0)") }
    exit(1)
}
