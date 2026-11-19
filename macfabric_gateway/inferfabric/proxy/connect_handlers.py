"""proxy.connect_handlers — 本机 Connect 控制面（F10，M3 Task 2）。

POST /admin/connect/apply、/admin/connect/rollback、GET /admin/connect/status
的请求门禁与转发。文件事务全部在 platform.clients.ConnectManager（Task 1），
本模块只做：对端/Host/Origin/token 门禁 → F7 key 校验 → 调用事务 → 错误映射。

安全裁决（计划 Task 2 + Review Focus 1/3）：
- 门禁先于读含 key 的 body；对端只信 socket peer（threaded
  client_address / async _peer_address，由 async_server._build_shim 从
  request.transport 注入），缺信息即拒绝，绝不读转发头。
- Host 必须精确等于实例回环 authority（端口错 = 403）；POST 必须携带
  同源 Origin（scheme+authority 全等，非宽松后缀匹配）。
- admin token 恒定时间比较；Connect 不继承 _admin_gate 的无 token 兼容
  放行 — 没有配置 token 一律 401。
- F7 key 校验：active_key_id(api_key) == key_id（同一 HMAC/摘要路径），
  不匹配/失效/store 缺失统一 400 invalid_key，不区分命中情况。
- 本模块不写日志（token/key 无泄漏面）；所有响应 Cache-Control: no-store，
  绝不回显 api_key / 原配置内容。
- HTTP 层不接收路径、URL、HOME 参数 — 目标文件由 ConnectManager 固定。
"""
from __future__ import annotations

import hmac
import json
import os
from pathlib import Path

from inferfabric.platform.clients import CLIENTS, ConnectError, ConnectManager
from inferfabric.proxy_manager import PROXY_HOST, PROXY_PORT

__all__ = ["handle_connect_status", "handle_connect_apply",
           "handle_connect_rollback"]

_NO_STORE = {"Cache-Control": "no-store"}

_CODE_STATUS = {
    "invalid_request": 400,
    "conflict": 409,
    "unavailable": 422,
    "io_error": 500,
}


def _authorities() -> tuple[str, ...]:
    """本实例可接受的精确回环 authority（Host/Origin 都按全等匹配）。"""
    return (f"127.0.0.1:{PROXY_PORT}", f"localhost:{PROXY_PORT}",
            f"[::1]:{PROXY_PORT}")


def _gateway_origin() -> str:
    # 写入客户端配置的 origin 恒用 127.0.0.1（本机兼容模式，与部署绑定无关）
    return f"http://127.0.0.1:{PROXY_PORT}"


def _get_manager() -> ConnectManager:
    codex = os.environ.get("CODEX_HOME")
    from inferfabric.config import IFF_DATA_DIR
    return ConnectManager(
        home=Path.home(),
        state_dir=IFF_DATA_DIR,
        gateway_origin=_gateway_origin(),
        codex_home=Path(codex) if codex else None,
    )


def _peer_host(h) -> str | None:
    """socket 对端主机；threaded 取 client_address，async 取 _peer_address。"""
    peer = getattr(h, "_peer_address", None)
    if peer is None:
        peer = getattr(h, "client_address", None)
    if not peer:
        return None
    if isinstance(peer, (tuple, list)):
        return str(peer[0]) if peer else None
    return str(peer)


def _configured_token(h) -> str:
    configured = getattr(h, "_admin_token", "")
    if configured:
        return str(configured)
    try:  # 延迟导入避免与 handler.py 循环
        from inferfabric.proxy.handler import _ADMIN_TOKEN
        return _ADMIN_TOKEN or ""
    except Exception:
        return ""


def _gate(h, *, write: bool) -> bool:
    """Connect 专用门禁；失败已发送 401/403 并返回 False。"""
    peer = _peer_host(h)
    if peer not in ("127.0.0.1", "::1", "localhost"):
        h._send_json({"error": "untrusted peer", "code": "forbidden"},
                     403, extra_headers=_NO_STORE)
        return False
    host = h.headers.get("Host", "")
    if host not in _authorities():
        h._send_json({"error": "untrusted host", "code": "forbidden"},
                     403, extra_headers=_NO_STORE)
        return False
    origin = h.headers.get("Origin")
    if origin is not None:
        ok_schemes = ("http://", "https://")
        origin_ok = any(origin == s + a for a in _authorities()
                        for s in ok_schemes)
    else:
        origin_ok = not write        # POST 必须显式携带同源 Origin
    if not origin_ok:
        h._send_json({"error": "untrusted origin", "code": "forbidden"},
                     403, extra_headers=_NO_STORE)
        return False
    token = h.headers.get("X-Admin-Token", "")
    configured = _configured_token(h)
    if not configured or not isinstance(token, str) or \
            not hmac.compare_digest(token, configured):
        h._send_json(
            {"error": "Unauthorized", "status": "unauthorized",
             "hint": "admin token required (X-Admin-Token); configure "
                     "MACFABRIC_ADMIN_TOKEN to enable management auth"},
            401, extra_headers=_NO_STORE)
        return False
    return True


def _send_error(h, code: str, message: str) -> None:
    h._send_json({"error": message, "code": code},
                 _CODE_STATUS.get(code, 500), extra_headers=_NO_STORE)


def _read_json(h) -> dict | None:
    try:
        raw = h._read_body()
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def _key_matches(key_id: str, api_key: str) -> bool:
    """F7 key 必须命中指定 ID 且处于活动状态（复用 _entry 的撤销/过期判定）。"""
    from inferfabric.config import IFF_DATA_DIR
    from inferfabric.security.key_store import KeyStore
    db_path = IFF_DATA_DIR / "security.db"
    if db_path.is_symlink() or not db_path.is_file():
        return False
    try:
        store = KeyStore(db_path)
        return store.active_key_id(api_key) == key_id
    except Exception:
        return False


def _send_inspect(h) -> None:
    mgr = _get_manager()
    h._send_json({"clients": [mgr.inspect(c) for c in CLIENTS]},
                 extra_headers=_NO_STORE)


def handle_connect_status(h, pm) -> None:
    if not _gate(h, write=False):
        return
    _send_inspect(h)


def handle_connect_apply(h, pm) -> None:
    if not _gate(h, write=True):
        return
    data = _read_json(h)
    if data is None:
        _send_error(h, "invalid_request", "invalid JSON body")
        return
    client = data.get("client")
    expected = data.get("expected_revision")
    key_id = data.get("key_id")
    api_key = data.get("api_key")
    if client not in CLIENTS or not isinstance(expected, str) or not expected:
        _send_error(h, "invalid_request", "invalid client or expected_revision")
        return
    if data.get("confirmed") is not True:
        _send_error(h, "invalid_request", "confirmed must be boolean true")
        return
    if not isinstance(key_id, str) or not key_id or \
            not isinstance(api_key, str) or not api_key:
        _send_error(h, "invalid_request", "key_id and api_key are required")
        return
    if not _key_matches(key_id, api_key):
        h._send_json({"error": "key rejected", "code": "invalid_key"},
                     400, extra_headers=_NO_STORE)
        return
    try:
        result = _get_manager().apply(client, expected_revision=expected,
                                      api_key=api_key)
    except ConnectError as exc:
        _send_error(h, exc.code, str(exc))
        return
    h._send_json(result, extra_headers=_NO_STORE)


def handle_connect_rollback(h, pm) -> None:
    if not _gate(h, write=True):
        return
    data = _read_json(h)
    if data is None:
        _send_error(h, "invalid_request", "invalid JSON body")
        return
    client = data.get("client")
    expected = data.get("expected_revision")
    if client not in CLIENTS or not isinstance(expected, str) or not expected:
        _send_error(h, "invalid_request", "invalid client or expected_revision")
        return
    if data.get("confirmed") is not True:
        _send_error(h, "invalid_request", "confirmed must be boolean true")
        return
    try:
        result = _get_manager().rollback(client, expected_revision=expected)
    except ConnectError as exc:
        _send_error(h, exc.code, str(exc))
        return
    h._send_json(result, extra_headers=_NO_STORE)
