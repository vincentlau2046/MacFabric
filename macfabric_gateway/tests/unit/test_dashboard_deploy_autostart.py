"""M2-T3 — deploy 页 autostart 开关：组装与源码契约（计划 2026-11-19 Task 3）。

数据源冻结：snapshot models[].{name,autostart}（manager.py list_models 已有
autostart 字段）；POST /admin/models/set-autostart {name,enabled} →
{status:"ok",model,autostart}。本任务不改后端。

源码契约钉住评审要点（Review Focus 3）：
- store 为快照打客户端请求序号；低于最近已应用序号的响应不回写状态/ETag；
  304 不作确认（不推进序号）。
- deploy 每模型单写在途；写后无条件发起快照确认读；确认读未到前显示
  「待回读确认」，不被轮询覆盖；受信快照与写值不同按服务端显示并提示不一致。
- 按钮注明「下次网关启动生效」；即时 switch/stop 复用推理页导航，不另造按钮。
"""
from pathlib import Path

from inferfabric import dashboard

JS_DIR = Path(dashboard._DASHBOARD_DIR) / "js"
FRAG_DIR = Path(dashboard._DASHBOARD_DIR) / "fragments"


def _src(name: str) -> str:
    return (JS_DIR / name).read_text(encoding="utf-8")


# ── 组装契约 ─────────────────────────────────────────────────────

def test_deploy_autostart_is_assembled():
    html = dashboard.get_html()
    # autostart 卡片容器真实存在于 deploy fragment（无需新 fragment 注册）
    assert 'id="depAutostart"' in html
    # store.js 已内联且带序号守卫（防占位符清空但守卫缺失）
    assert "snapshot_seq" in html


# ── store.js 序号守卫契约 ────────────────────────────────────────

def test_store_snapshot_sequence_guard():
    src = _src("store.js")
    # 客户端请求序号：每次请求递增；200 应用时推进已应用序号并暴露 snapshot_seq
    assert "_reqSeq" in src
    assert "_snapSeq" in src
    assert "snapshot_seq" in src
    # 低于最近已应用序号的响应整包丢弃（不回写状态/ETag）
    assert "seq <" in src or "seq <= " in src


# ── deploy.js 行为契约 ───────────────────────────────────────────

def test_deploy_js_autostart_write_flow():
    src = _src("deploy.js")
    assert "admin/models/set-autostart" in src
    assert "UI.adminHeaders" in src
    # 每模型单写在途（防连点重复 POST）
    assert "_inflight" in src
    # 写后无条件确认读；确认读未到显示「待回读确认」；不一致按服务端显示并提示
    assert "forceRefreshEx" in src
    assert "待回读确认" in src
    assert "不一致" in src
    # 确认读门槛 = 确认读请求自身的发出序号（终审 Important-2：写前在途
    # 轮询的序号可能恰为 appliedSeq()+1，不得充当确认读）
    assert "minSeq" in src
    # 明示生效时机
    assert "下次网关启动生效" in src
    # 即时 switch/stop 复用推理页导航
    assert "tab-inference" in src


def test_store_forceRefreshEx_returns_request_seq():
    src = _src("store.js")
    # fetchSnapshotEx 返回 {seq, snap}（本次请求的发出序号 + 应用结果）；
    # fetchSnapshot 保持旧签名/返回（兼容轮询与既有调用方）
    assert "fetchSnapshotEx" in src
    assert "return { seq: seq, snap: snap }" in src


def test_deploy_html_autostart_card():
    frag = (FRAG_DIR / "deploy.html").read_text(encoding="utf-8")
    assert 'id="depAutostart"' in frag


def test_deploy_js_no_inline_onclick():
    src = _src("deploy.js")
    assert "onclick=" not in src
