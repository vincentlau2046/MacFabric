"""Task 2 — 本机 Connect 控制面（F10，/admin/connect/*）。

契约（计划 Task 2 Interfaces + Review Focus 1/3）：
- GET /admin/connect/status → {clients:[{client,state,target,revision},...]}
- POST /admin/connect/apply {client,expected_revision,confirmed:true,key_id,api_key}
- POST /admin/connect/rollback {client,expected_revision,confirmed:true}
- 错误映射：输入/确认缺失 400、token 缺失或错误 401、来源或对端拒绝 403、
  配置不可用 422、revision 冲突 409、文件 I/O 500；F7 不匹配/失效统一
  400 invalid_key（不区分命中情况）。
- 门禁先于读含 key 的 body；对端只信 socket peer（threaded client_address /
  async request.transport peername），绝不相信转发头；Host 必须精确等于实例
  回环 authority；POST 必须带同源 Origin；admin token 恒定时间比较，
  Connect 不继承无 token 兼容放行。
- 成功/失败响应一律 Cache-Control: no-store，绝不回显 api_key，不写日志。

repo 无 aiohttp 测试夹具（Ruling，同 test_admin_models_remove.py）：
handler 函数级假 self 直测 + 路由表注册断言；threaded/async 差异只在
对端地址来源（client_address vs _peer_address），参数化覆盖。
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from inferfabric.proxy import connect_handlers

ADMIN = "test-admin-token"
HOST = "127.0.0.1:8999"
ORIGIN = f"http://{HOST}"


# ── 假 self（函数级直测）─────────────────────────────────────────

class _H:
    def __init__(self, *, headers, body=b"", peer=None, async_peer=None,
                 admin_token=ADMIN):
        self.headers = headers
        self._body = body
        self._sent = []
        self._admin_token = admin_token
        if peer is not None:
            self.client_address = peer          # threaded 模式
        if async_peer is not None:
            self._peer_address = async_peer     # async 模式（_build_shim 注入）

    def _read_body(self):
        return self._body

    def _send_json(self, data, status=200, extra_headers=None):
        self._sent.append((data, status, extra_headers or {}))


def _post_headers(token=ADMIN, host=HOST, origin=ORIGIN):
    h = {}
    if token is not None:
        h["X-Admin-Token"] = token
    if host is not None:
        h["Host"] = host
    if origin is not None:
        h["Origin"] = origin
    return h


def _apply_body(**over):
    body = {"client": "claude", "expected_revision": "absent",
            "confirmed": True, "key_id": "kid", "api_key": "sk-f7-x"}
    body.update(over)
    return json.dumps(body).encode()


def _wire(tmp_path, monkeypatch, client="claude"):
    """真实 ConnectManager 指向 tmp 目录 + 真实 F7 store。"""
    from inferfabric.platform.clients import ConnectManager
    home = tmp_path / "home"
    if client == "claude":
        (home / ".claude").mkdir(parents=True)
        target = home / ".claude" / "settings.json"
    else:
        codex = tmp_path / "codex"
        codex.mkdir(parents=True)
        target = codex / "config.toml"
    mgr = ConnectManager(home=home, state_dir=tmp_path / "state",
                         gateway_origin=ORIGIN,
                         codex_home=tmp_path / "codex" if client == "codex" else None)
    monkeypatch.setattr(connect_handlers, "_get_manager", lambda: mgr)

    iff = tmp_path / "iff"
    iff.mkdir()
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", iff)
    from inferfabric.security.key_store import KeyStore
    store = KeyStore(iff / "security.db", provision=True)
    return mgr, target, store


def _last(h):
    return h._sent[-1]


# ── 1. 门禁：对端 / Host / Origin / token（threaded + async 参数化）──

@pytest.fixture()
def wired(tmp_path, monkeypatch):
    mgr, target, store = _wire(tmp_path, monkeypatch)
    kid, token = store.create_key("test-key", None, None)
    return {"kid": kid["id"], "token": token, "target": target}


def _call_apply(peer=None, async_peer=None, headers=None, body=None,
                admin_token=ADMIN):
    h = _H(headers=headers or _post_headers(), body=body or _apply_body(),
           peer=peer, async_peer=async_peer, admin_token=admin_token)
    connect_handlers.handle_connect_apply(h, None)
    return h


@pytest.mark.parametrize("use_async", [False, True])
def test_connect_admin_requires_token_and_real_loopback(wired, use_async):
    ok_peer = ("127.0.0.1", 51234)
    kw = {"async_peer": ok_peer} if use_async else {"peer": ok_peer}

    # 非回环对端：即使伪造转发头声明回环来源也 403
    forged = _post_headers()
    forged["X-Forwarded-For"] = "127.0.0.1"
    forged["Forwarded"] = "for=127.0.0.1"
    h = _call_apply(peer=("192.168.1.7", 5555) if not use_async else None,
                    async_peer=("192.168.1.7", 5555) if use_async else None,
                    headers=forged)
    assert _last(h)[1] == 403
    assert not wired["target"].exists()

    # 缺 admin token → 401
    h = _call_apply(headers=_post_headers(token=None), **kw)
    assert _last(h)[1] == 401

    # 错 admin token → 401
    h = _call_apply(headers=_post_headers(token="wrong"), **kw)
    assert _last(h)[1] == 401

    # 错误端口 / 错误 Host / 跨站 Origin / 缺 Origin → 403
    for headers in (_post_headers(host="127.0.0.1:9999"),
                    _post_headers(host="evil.example:8999"),
                    _post_headers(origin="http://evil:8999"),
                    _post_headers(origin=None)):
        h = _call_apply(headers=headers, **kw)
        assert _last(h)[1] == 403, headers
    assert not wired["target"].exists()

    # 对端信息缺失（两处属性都拿不到）→ 403
    h = _H(headers=_post_headers(), body=_apply_body(),
           admin_token=ADMIN)
    connect_handlers.handle_connect_apply(h, None)
    assert _last(h)[1] == 403
    assert not wired["target"].exists()

    # 同源 + 有效 token + 有效 key → 200 托管成功（正向放最后）
    body = _apply_body(key_id=wired["kid"], api_key=wired["token"])
    h = _call_apply(headers=_post_headers(), body=body, **kw)
    obj, status, _ = _last(h)
    assert status == 200
    assert obj["state"] == "managed"
    assert wired["target"].exists()


def test_connect_gate_on_status_get(wired):
    # GET /status：Origin 可省；token 错误仍 401；Host 错误 403
    h = _H(headers={"X-Admin-Token": ADMIN, "Host": HOST},
           peer=("127.0.0.1", 5000))
    connect_handlers.handle_connect_status(h, None)
    obj, status, _ = _last(h)
    assert status == 200
    assert [c["client"] for c in obj["clients"]] == ["claude", "codex"]
    assert all(set(c) == {"client", "state", "target", "revision"}
               for c in obj["clients"])

    h = _H(headers={"Host": HOST}, peer=("127.0.0.1", 5000))
    connect_handlers.handle_connect_status(h, None)
    assert _last(h)[1] == 401

    h = _H(headers={"X-Admin-Token": ADMIN, "Host": "127.0.0.1:1"},
           peer=("127.0.0.1", 5000))
    connect_handlers.handle_connect_status(h, None)
    assert _last(h)[1] == 403


# ── 2. F7 key 必须与所选 ID 匹配且有效 ───────────────────────────

def test_connect_only_accepts_matching_active_f7_key(wired, tmp_path,
                                                     monkeypatch):
    kid, token = wired["kid"], wired["token"]

    def _call(k, t):
        return _call_apply(headers=_post_headers(),
                           body=_apply_body(key_id=k, api_key=t),
                           peer=("127.0.0.1", 5000))

    # 正确配对 → 200，配置落盘
    obj, status, _ = _last(_call(kid, token))
    assert status == 200
    assert wired["target"].exists()

    # 另一个 ID 的有效 key（ID/token 交叉）→ invalid_key
    from inferfabric.security.key_store import KeyStore
    store = KeyStore(tmp_path / "iff" / "security.db")
    kid2, token2 = store.create_key("second", None, None)
    h = _call(kid, token2)          # ID 用 key1、token 用 key2
    assert _last(h)[1] == 400
    assert _last(h)[0]["code"] == "invalid_key"

    # 撤销后的 key → invalid_key
    store.revoke_key(kid2["id"])
    h = _call(kid2["id"], token2)
    assert _last(h)[1] == 400
    assert _last(h)[0]["code"] == "invalid_key"

    # admin token 冒充 F7 key → invalid_key
    h = _call(kid, ADMIN)
    assert _last(h)[1] == 400
    assert _last(h)[0]["code"] == "invalid_key"

    # 未知 ID → invalid_key
    h = _call("deadbeef", token)
    assert _last(h)[1] == 400
    assert _last(h)[0]["code"] == "invalid_key"

    # 以上失败全程不落盘：文件内容仍是首次成功托管的（或不存在时的语义）
    assert wired["target"].exists()


def test_key_check_fails_closed_when_store_missing(wired, tmp_path,
                                                   monkeypatch):
    # store 缺失/损坏 → 统一 invalid_key，fail-closed
    (tmp_path / "iff" / "security.db").unlink()
    h = _call_apply(headers=_post_headers(),
                    body=_apply_body(key_id=wired["kid"],
                                     api_key=wired["token"]),
                    peer=("127.0.0.1", 5000))
    assert _last(h)[1] == 400
    assert _last(h)[0]["code"] == "invalid_key"
    assert not wired["target"].exists()


# ── 3. confirmed 严格为布尔 True ─────────────────────────────────

@pytest.mark.parametrize("confirmed", [None, False, "true", 1])
def test_apply_and_rollback_confirm_are_strict_true(wired, confirmed):
    for handler, body in (
            (connect_handlers.handle_connect_apply,
             _apply_body(key_id=wired["kid"], api_key=wired["token"],
                         confirmed=confirmed)),
            (connect_handlers.handle_connect_rollback,
             json.dumps({"client": "claude",
                         "expected_revision": "absent",
                         "confirmed": confirmed}).encode())):
        h = _H(headers=_post_headers(), body=body, peer=("127.0.0.1", 5000))
        handler(h, None)
        obj, status, _ = _last(h)
        assert status == 400, confirmed
        assert obj["code"] == "invalid_request"


# ── 4. 输入校验与错误映射 ────────────────────────────────────────

def test_apply_input_validation_and_error_mapping(wired):
    # 未知 client → 400
    h = _call_apply(headers=_post_headers(),
                    body=_apply_body(client="zed",
                                     key_id=wired["kid"],
                                     api_key=wired["token"]),
                    peer=("127.0.0.1", 5000))
    assert _last(h)[1] == 400
    assert _last(h)[0]["code"] == "invalid_request"

    # 非法 JSON → 400
    h = _call_apply(headers=_post_headers(), body=b"{nope",
                    peer=("127.0.0.1", 5000))
    assert _last(h)[1] == 400

    # revision 冲突 → 409（先写一次，再用旧 revision）
    h = _call_apply(headers=_post_headers(),
                    body=_apply_body(key_id=wired["kid"],
                                     api_key=wired["token"]),
                    peer=("127.0.0.1", 5000))
    assert _last(h)[1] == 200
    stale = json.loads(wired["target"].read_text())
    stale["env"]["OTHER"] = "x"
    wired["target"].write_text(json.dumps(stale))
    h = _call_apply(headers=_post_headers(),
                    body=_apply_body(key_id=wired["kid"],
                                     api_key=wired["token"]),
                    peer=("127.0.0.1", 5000))
    assert _last(h)[1] == 409
    assert _last(h)[0]["code"] == "conflict"


def test_rollback_needs_admin_only(wired):
    kid, token = wired["kid"], wired["token"]
    h = _call_apply(headers=_post_headers(),
                    body=_apply_body(key_id=kid, api_key=token),
                    peer=("127.0.0.1", 5000))
    rev = _last(h)[0]["revision"]
    # 回退不需要 F7 key 仍有效
    h = _H(headers=_post_headers(),
           body=json.dumps({"client": "claude", "expected_revision": rev,
                            "confirmed": True}).encode(),
           peer=("127.0.0.1", 5000))
    connect_handlers.handle_connect_rollback(h, None)
    obj, status, _ = _last(h)
    assert status == 200
    assert obj["state"] == "missing_file"   # 原文件本不存在 → 回退即移除


# ── 5. no-store / 不回显 / 无日志 ────────────────────────────────

def test_connect_routes_no_store_and_do_not_disclose_token(wired):
    from inferfabric.proxy.handler import _GET_ROUTES, _POST_ROUTES

    assert "/admin/connect/status" in _GET_ROUTES
    assert "/admin/connect/apply" in _POST_ROUTES
    assert "/admin/connect/rollback" in _POST_ROUTES

    kid, token = wired["kid"], wired["token"]
    body = _apply_body(key_id=kid, api_key=token)

    # 成功响应：200 + no-store + 不含 key 明文
    h = _call_apply(headers=_post_headers(), body=body,
                    peer=("127.0.0.1", 5000))
    obj, status, headers = _last(h)
    assert status == 200
    assert headers.get("Cache-Control") == "no-store"
    assert token not in json.dumps(obj)

    # 失败响应：同样 no-store + 不回显
    h = _call_apply(headers=_post_headers(),
                    body=_apply_body(key_id=kid, api_key="sk-wrong"),
                    peer=("127.0.0.1", 5000))
    obj, status, headers = _last(h)
    assert status == 400
    assert headers.get("Cache-Control") == "no-store"
    assert "sk-wrong" not in json.dumps(obj)
    assert token not in json.dumps(obj)

    # 无 token 日志：connect_handlers 不使用 logging 输出请求内容
    src = Path(connect_handlers.__file__).read_text(encoding="utf-8")
    assert "log." not in src


def test_async_shim_passes_peer_address():
    """async 模式对端来自 request.transport.get_extra_info('peername')。"""
    from pathlib import Path as _P
    import inferfabric.proxy.async_server as async_server
    src = _P(async_server.__file__).read_text(encoding="utf-8")
    assert "_peer_address" in src
    assert "get_extra_info" in src
