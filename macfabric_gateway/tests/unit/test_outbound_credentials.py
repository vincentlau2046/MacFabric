"""Task 5 — 出站账号池占位（F6，M3 T5）：不改行为的 selector 接线合同。

契约（计划 Task 5 Interfaces + Review Focus 5）：
- select_outbound_api_key(*, provider_name, configured_api_key) -> str
  默认原样返回 configured_api_key（普通/空字符串），无任何新配置键、
  配额读写、轮转、粘连、重试策略、持久化、后台任务或遥测。
- 注入点：forward_to_cloud 在协议能力/端点校验通过后、首次组装鉴权
  header 前调用一次；同次转发的重试沿用同一选定值。
- 双协议共享：OpenAI 走 Authorization: Bearer，Anthropic 走 x-api-key；
  路径/重试次数/空 key 语义保持既有行为。
- 入站 F7 标记（key_name / 入站 token）从不进入 selector 参数。
"""
import http.server
import io
import json
import threading
import types

import pytest

from inferfabric import forwarder, outbound_credentials

CONFIGURED = "sk-configured-outbound"
SELECTED = "sk-selected-outbound"


def test_default_outbound_selector_returns_configured_key_unchanged():
    assert outbound_credentials.select_outbound_api_key(
        provider_name="prov-a", configured_api_key=CONFIGURED) == CONFIGURED
    assert outbound_credentials.select_outbound_api_key(
        provider_name="prov-a", configured_api_key="") == ""


def test_selector_signature_is_keyword_only_no_extras():
    import inspect
    sig = inspect.signature(outbound_credentials.select_outbound_api_key)
    assert list(sig.parameters) == ["provider_name", "configured_api_key"]


# ── forwarder 接线（真实回环 stub） ──────────────────────────────

class _Stub(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        self.server.reqs.append({
            "path": self.path,
            "auth": self.headers.get("Authorization"),
            "xkey": self.headers.get("x-api-key"),
        })
        if self.server.fail_first and len(self.server.reqs) == 1:
            body = b'{"error": "transient"}'
            self.send_response(500)
        else:
            body = json.dumps({"usage": {"prompt_tokens": 1,
                                         "completion_tokens": 1}}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class _FakeHandler:
    def __init__(self):
        self.sent = []
        self.path = "/v1/chat/completions"     # send_json 的 CORS 判定用
        self.wfile = io.BytesIO()              # send_json 直写体（丢弃）
        self._key_name = "f7-inbound-marker"   # 入站 F7 标记

    def send_response(self, s):
        self.sent.append(("status", s))

    def send_header(self, k, v):
        self.sent.append(("hdr", k, v))

    def end_headers(self):
        pass

    def _safe_write(self, b):
        pass


def _make_stub(fail_first=False):
    srv = http.server.HTTPServer(("127.0.0.1", 0), _Stub)
    srv.reqs = []
    srv.fail_first = fail_first
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def _provider(port, protocol):
    cfg = types.SimpleNamespace(
        name="prov-a", api_key=CONFIGURED, timeout=5,
        openai_available=True, anthropic_available=True,
        openai_base=f"http://127.0.0.1:{port}/v1",
        anthropic_base=f"http://127.0.0.1:{port}/v1")
    cloud_model = types.SimpleNamespace(
        model_id="cloud-model-x", openai_available=True,
        anthropic_available=True)
    return cfg, cloud_model


def _run(srv, protocol, handler=None):
    h = handler or _FakeHandler()
    cfg, cm = _provider(srv.server_address[1], protocol)
    result = forwarder.forward_to_cloud(h, {"model": "x"}, cfg, cm,
                                        protocol=protocol)
    return h, result


def test_forwarder_openai_outgoing_header_uses_configured_key():
    srv = _make_stub()
    try:
        h, result = _run(srv, "openai")
        assert result.status == 200
        assert srv.reqs[0]["path"].endswith("/chat/completions")
        assert srv.reqs[0]["auth"] == "Bearer " + CONFIGURED   # 默认原样透传
        assert srv.reqs[0]["xkey"] is None
    finally:
        srv.shutdown()


def test_forwarder_anthropic_outgoing_header_uses_configured_key():
    srv = _make_stub()
    try:
        h, result = _run(srv, "anthropic")
        assert result.status == 200
        assert srv.reqs[0]["path"].endswith("/messages")
        assert srv.reqs[0]["xkey"] == CONFIGURED               # 默认原样透传
        assert srv.reqs[0]["auth"] is None
    finally:
        srv.shutdown()


def test_selector_called_once_per_forward_with_only_contract_kwargs(monkeypatch):
    srv = _make_stub()
    calls = []

    def _spy(*, provider_name, configured_api_key):
        calls.append({"provider_name": provider_name,
                      "configured_api_key": configured_api_key})
        return SELECTED

    monkeypatch.setattr(forwarder.outbound_credentials,
                        "select_outbound_api_key", _spy)
    try:
        h, result = _run(srv, "openai")
        assert result.status == 200
        assert len(calls) == 1                                  # 每转发一次
        assert set(calls[0]) == {"provider_name",
                                 "configured_api_key"}          # 固定参数面
        assert "f7-inbound-marker" not in json.dumps(calls)     # F7 不入参
        assert srv.reqs[0]["auth"] == "Bearer " + SELECTED      # 选定值出站
    finally:
        srv.shutdown()


def test_retry_reuses_same_selected_key(monkeypatch):
    srv = _make_stub(fail_first=True)
    n_calls = []

    def _spy(*, provider_name, configured_api_key):
        n_calls.append(1)
        return SELECTED

    monkeypatch.setattr(forwarder.outbound_credentials,
                        "select_outbound_api_key", _spy)
    monkeypatch.setattr(forwarder.time, "sleep", lambda s: None)  # 退避免等
    try:
        h, result = _run(srv, "openai")
        assert result.status == 200
        assert len(srv.reqs) == 2                               # 一次重试
        assert len(n_calls) == 1                                # selector 仅一次
        assert all(r["auth"] == "Bearer " + SELECTED
                   for r in srv.reqs)                           # 重试沿用同值
    finally:
        srv.shutdown()


def test_empty_key_header_semantics_unchanged(monkeypatch):
    # 空 key：header 行为与既有语义一致（Bearer 空 / x-api-key 空），不抛错
    srv = _make_stub()
    try:
        h = _FakeHandler()
        cfg, cm = _provider(srv.server_address[1], "openai")
        cfg.api_key = ""
        result = forwarder.forward_to_cloud(h, {"model": "x"}, cfg, cm,
                                            protocol="openai")
        assert result.status == 200
        assert srv.reqs[0]["auth"] == "Bearer "                 # 既有语义：空 Bearer
    finally:
        srv.shutdown()
