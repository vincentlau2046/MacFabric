# 能力包页标签统一梳理（小版本方案，2026-11-17）

> 用户裁决：这版表格 OK；能力包页标签纳入下一个 PR 落地的小版本。
> 本文是实施依据；实施时走 TDD（先在 Tests/main.swift 加断言，RED→GREEN）。
> **状态：已于 2026-11-17 按 TDD 实施（RED 9 失败→GREEN 22 组全过），证据见 docs/qa/product-v2/native-ui.md。**

## 现状（2026-11-17 核实）

- 目录 4 个内置包的 `tags` 是自由描述串：`chat/tools/multilingual`、`embedding/retrieval/multilingual`、`tts/english/low-latency`、`ocr/builtin/zero-download`；自定义包固定 `custom`。
- App 侧 `PacksView.packRows` 把 tags 原文直接塞进 `CapabilityTag(id:label:)` —— 表格"能力"列显示英文原串，与全 fabric 标准词汇（看图/对话/嵌入…）不对齐。
- `capability` 字段（llm/embedding/tts/ocr…）才是规范类型，且必填——用它做主标签锚点。
- 标准口径唯一出处：`ProductModels.swift` 的 `CapabilityTag`；看图 = id `vision`（云端来自 supports_vision，VL 类型走类型列眼睛图标）。

## 语义红线（用户裁决 2026-11-17，优先级高于映射表）

1. **标签纯展示，绝不做门禁**：路由/调用行为仍由网关既有逻辑全权负责；App 侧任何标签不得反向约束请求，语义翻转会导致 agent 不可用。
2. **三态沿用（不新增口径）**：能力沿用网关 `model_specs`/`routable_caps` 三态 ——
   `None`=未声明（不显示该能力标签，也**不得**显示"不支持"）；
   `true`=显示能力标签；
   `false`=显式排除（详情栏如实标注"不支持"，表格不显示标签）。
   严禁 bool() 塌缩（7.8.0 cross-review I-1 既有裁决）。
3. **LLM 工具调用沿用既有 inferfabric 逻辑**：llama.cpp `--jinja`、anthropic_native 等既有事实为准，App 不新增门禁、不降级显示；声明来源是既有 model_specs 打标管道。
4. **VL/看图必须显式**：识别或人工打标（model_specs tag）；未声明一律不显示看图标签（现状 `supports_vision == true` 判定符合，保持）。
5. **其余能力默认支持**：按 `capability` 类型给主标签（llm→对话、embedding→嵌入/检索…），这属于类型事实，不是能力声明，不与三态混淆。

## 方案

**一处定义标准标签目录**（ProductModels.swift 新增 `CapabilityTags`），三层映射，上游 payload 不改：

1. **主标签（规范，必显示）**：由 `capability` 映射 →
   llm→对话 · vl→看图 · embedding→嵌入/检索 · rerank→重排 ·
   asr→语音转写 · tts→语音合成 · ocr→文字识别 · aigc→生图 · 其他→原文（诚实）
2. **修饰标签（次级，已知词映射，未知词原样透传）**：
   tools→工具调用 · multilingual→多语 · retrieval→检索 · low-latency→低延迟 ·
   builtin→内置 · zero-download→零下载 · custom→自定义 · chat 不重复映射（与主标签同义时去重）
3. **呈现规则**：表格"能力"列 = 主标签在前 + 至多 2 个修饰标签；详情栏给全量；
   眼睛图标规则不变（capabilities 含 id `vision` 即显示）。

## 验收（TDD 断言，进 Tests/main.swift）

- fixture 补 tags 数据：`capability=llm, tags=[chat,tools,multilingual]` → 能力列文本含"对话""工具调用"，不含"chat"原串
- 未知 tag 原样透传（如 `future-cap` 不映射也不丢）
- 自定义包 `custom` → "自定义"
- vision 主标签 = 现行 id（回归：看图图标判定不变）
- **三态回归**：`supports_vision=nil` 不产生看图标签；`=false` 不产生看图标签且详情有"不支持"；`=true` 产生（防语义翻转）

## 范围外（明确不做）

- 网关 catalog payload 结构不动（映射纯 App 侧）
- 模型池页标签呈现（池无标签面，后续有需求另立）
- C 阶段目录贯通后的上游 tags 规范化（届时网关侧对齐）
