# MacFabric

**Apple Silicon 上的小模型多协议聚合平台** — 本机端侧能力（对话 / 看图 / 嵌入 / 重排 / ASR / TTS / OCR / 文生图）+ 云端大模型聚合，统一经 `:8999` 网关以 OpenAI / Anthropic 双协议暴露。原生 SwiftUI App + 菜单栏常驻，单 dmg 安装、零终端。

> 定制自 [InferFabric](https://github.com/vincentlau2046/InferFabric)（Atlas 本地推理底座）—— 保留其有状态网关内核（双协议路由 / 逻辑模型池 / 云聚合 / 治理链），退役其 CUDA 部署线，为 Mac 重建了内存账本状态机、Mac 引擎适配器与原生 UI。

## 当前状态

**规划与设计阶段 → P0 进行中**。

- 📐 实施基线：[docs/PLAN.md](docs/PLAN.md)（14 项已裁决结论 + 内存三规则 + 引擎矩阵 + 里程碑）
- 🎨 UI 设计稿：[design/ui-design-v0.html](design/ui-design-v0.html)（11 个画面高保真稿 + 设计令牌，浏览器打开即可查看）

## 产品原则

1. **本地 LLM ≤4B 封顶**，大模型需求走云端聚合
2. **内存账本三规则**：`B = RAM − 8G` 唯一预算；常驻/按需二分装载；内存压力自动卸载空闲按需模型
3. **所有模型一个地址**：本机与云端都经 `:8999` 调用，密钥永不外露，客户端零改动
4. **少即是多**：每屏一个主操作，每条规则能用一句话说完

## 路线图

| 阶段 | 内容 |
|---|---|
| P0 | Mac 上跑通网关基线（Metal llama.cpp + Ollama，双协议 + 模型池回归） |
| P1 | 内核 Mac 化（内存账本 / 翻译层 / launchd / ocr-helper） |
| P2 | 原生 SwiftUI App（菜单栏 + 总览 / 模型服务 / 本地推理 / 模型池 / 监控台） |
| P3 | 能力包（ASR / TTS / OCR / 嵌入 / 重排 / 生图 开箱预设） |
| P4 | 打磨（dmg 引导安装 / Sparkle / Shortcuts / 公证分发） |

## License

MIT（与上游一致）
