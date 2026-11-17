"""批 1 TOP1 控制面鉴权 — born-token / fail-closed / Host·Origin 校验 / secrets 隔离。

契约（spec docs/superpowers/specs/2026-11-17-batch1-auth-network-state.md）：
- SecretsManager 路径派生随 CloudDiscovery config_path.parent（dev 状态目录隔离）
- _ensure_admin_token：secrets.env 缺 MACFABRIC_ADMIN_TOKEN 时生成写回（600）；
  已有则原样读取（重启轮换语义 = 用户改文件 → 重启生效）
- _check_admin/_admin_gate：无 token 配置 → 401 fail-closed（不再放行）；
  token 匹配 → 放行；不匹配 → 401
- Host/Origin：Host 非回环 → 403；写请求带跨站 Origin → 403；
  原生 App（无 Origin）→ 放行
- _validate_admin_token_safety：空 token 一律 RuntimeError（双保险）
"""

import os
import stat

import pytest

from inferfabric.cloud_discovery import CloudDiscovery, SecretsManager
from inferfabric.proxy import handler as proxy_handler


def _read_env_file(path):
    result = {}
    if not path.exists():
        return result
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            result[k.strip()] = v.strip()
    return result


# ── Secrets 路径派生（dev 隔离缺陷修复）──

def test_cloud_discovery_secrets_follow_config_dir(tmp_path):
    """config_path 在 dev 目录 → secrets.env 也在 dev 目录（不再硬编码 ~/.inferfabric）。"""
    cfg = tmp_path / "cloud_provider.yaml"
    cfg.write_text("providers: {}\n")
    cd = CloudDiscovery(cfg)
    assert cd.secrets.path == tmp_path / "secrets.env"


# ── born-token ──

def test_born_token_generates_when_missing(tmp_path, monkeypatch):
    env_file = tmp_path / "secrets.env"
    monkeypatch.delenv("IFF_ADMIN_TOKEN", raising=False)
    token = proxy_handler._ensure_admin_token(env_file)
    assert token, "born token must be non-empty"
    data = _read_env_file(env_file)
    assert data.get("MACFABRIC_ADMIN_TOKEN") == token
    assert stat.S_IMODE(env_file.stat().st_mode) == 0o600
    # 幂等：再取同值（不轮换）
    assert proxy_handler._ensure_admin_token(env_file) == token


def test_born_token_reads_existing_value(tmp_path):
    env_file = tmp_path / "secrets.env"
    env_file.write_text("MACFABRIC_ADMIN_TOKEN=existing-value-123\n# comment\nOTHER=x\n")
    env_file.chmod(0o600)
    assert proxy_handler._ensure_admin_token(env_file) == "existing-value-123"


def test_born_token_env_override_wins(tmp_path, monkeypatch):
    """显式 IFF_ADMIN_TOKEN 优先于 secrets.env（运维紧急通道）。"""
    monkeypatch.setenv("IFF_ADMIN_TOKEN", "explicit-ops-token")
    assert proxy_handler._ensure_admin_token(tmp_path / "secrets.env") == "explicit-ops-token"


# ── fail-closed + Host/Origin ──

class _FakeHandler:
    """校验逻辑的最小替身（只测 _admin_gate 纯函数，不走 socket）。"""

    def __init__(self, headers, admin_token):
        self.headers = headers
        self._admin_token = admin_token
        self.replied = None

    def _send_json(self, data, status=200):
        self.replied = (data, status)


def test_admin_gate_fail_closed_without_token():
    h = _FakeHandler({}, admin_token="")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999") is False
    assert h.replied[1] == 401


def test_admin_gate_accepts_matching_token():
    h = _FakeHandler({"X-Admin-Token": "tok-abc"}, admin_token="tok-abc")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999") is True
    assert h.replied is None


def test_admin_gate_rejects_wrong_token():
    h = _FakeHandler({"X-Admin-Token": "wrong"}, admin_token="tok-abc")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999") is False
    assert h.replied[1] == 401


def test_admin_gate_rejects_non_loopback_host():
    h = _FakeHandler({"X-Admin-Token": "tok-abc", "Host": "0.0.0.0:8999"}, admin_token="tok-abc")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999") is False
    assert h.replied[1] == 403


def test_admin_gate_rejects_cross_site_origin_on_write():
    h = _FakeHandler({"X-Admin-Token": "tok-abc", "Origin": "http://evil.example"},
                     admin_token="tok-abc")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999", write=True) is False
    assert h.replied[1] == 403


def test_admin_gate_allows_native_app_no_origin():
    h = _FakeHandler({"X-Admin-Token": "tok-abc"}, admin_token="tok-abc")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999", write=True) is True


def test_admin_gate_allows_loopback_origin():
    h = _FakeHandler({"X-Admin-Token": "tok-abc", "Origin": "http://127.0.0.1:8999"},
                     admin_token="tok-abc")
    assert proxy_handler._admin_gate(h, "127.0.0.1:8999", write=True) is True


def test_validate_admin_token_safety_raises_on_empty(monkeypatch):
    monkeypatch.setattr(proxy_handler, "_ADMIN_TOKEN", "")
    with pytest.raises(RuntimeError):
        proxy_handler._validate_admin_token_safety()
