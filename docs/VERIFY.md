# MacFabric 晨间校验指南（2026-11-14）

## 一键验收

```bash
cd /Users/Apple/Projects/MacFabric

# 1. 网关（应已在跑；若没有）
#    注意：launchd 服务【未激活】（需你亲自批准开机自启），手动启动：
PYTHONPATH=$PWD/macfabric_gateway .venv/bin/python -m inferfabric.proxy.handler &
#    或批准开机自启：./scripts/install-launchd.sh install

# 2. 加载基线模型
PYTHONPATH=$PWD/macfabric_gateway .venv/bin/python -m inferfabric.cli switch qwen3-4b

# 3. 双协议冒烟
curl -s http://127.0.0.1:8999/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"qwen3-4b","max_tokens":200,"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"user","content":"1+1=?只回答数字"}]}'
curl -s http://127.0.0.1:8999/v1/messages -H "Content-Type: application/json" \
  -d '{"model":"qwen3-4b","max_tokens":200,"messages":[{"role":"user","content":"你好"}]}'

# 4. 单元测试（31 项：内存账本三规则 / 平台层 / 翻译层 golden replay）
cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/ -q

# 5. 原生 App
open macfabric-app/build/MacFabric.app   # 菜单栏常驻 + 三页窗口

# 6. OCR 冒烟
./tools/ocr-helper --selftest
```

## 今晚完成

- **P0 全部**：Metal 推理（llama.cpp b12361，Qwen3-4B 全量 offload）、双协议（OpenAI+Anthropic、流式+非流式）实测通过
- **P1 主体**：Mac 平台层（lsof/统一内存/预算 B）、内存账本三规则+四态生命周期（19 测试）、Anthropic↔OpenAI 翻译层+桥接+golden replay（31 测试全绿）、llama 二进制配置化（Metal 第一公民）、ocr-helper、launchd/uv 打包脚本
- **P2 骨架**：SwiftUI 原生 App（菜单栏+总览/模型服务/本地推理）构建+冒烟通过

## 需要你裁决的事

1. **launchd 开机自启**（`scripts/install-launchd.sh install`）——被权限系统拦下，属开机持久化，等你亲自执行批准。
2. GitHub 偶发 HTTP2 framing 错误——推送失败时用 `git -c http.version=HTTP/1.1 push origin main` 重试。
3. 三项悬而未决（不阻塞）：UI 语言跟随系统（建议是）/ 菜单栏聊天入口（建议 v1 不做）/ 局域网共享（建议 v1.5）。

## 明细日志见 docs/STATUS.md；里程碑提交（双仓库同步）：

- `8582984` P0：分叉包 + 双协议 Metal 验证
- `385ac63` P1-1：平台层 + 内存账本 + 二进制配置
- `7cdd0a1` P1-2：翻译层 + golden replay
- `1161028` P1-3：OCR helper + launchd 打包
- （本次）P2-1：SwiftUI 原生骨架
