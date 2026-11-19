"""① dashboard iff remove 入口 — deploy 页 UI 组装与源码契约（上游 issue #8 item 1）。

后端：POST /admin/models/remove {name, confirmed?, purge_pools?}（接线合同由
test_admin_models_remove.py 钉住；remove_model 本体语义由 test_uninstaller.py 钉住）。

源码契约钉住与 peer 对齐的四点方案（浏览器验收在沙箱另行执行）：
- 三段式确认：预览（无 confirmed，零副作用）→ 展示报告（blocked 时给
  purge 选项 + 「重新预览」二次预览）→ confirmed:true 执行；
- running 三值文案：运行中（将先停止服务）/ 未运行 / 状态未知；
- scenario_refs 明示「移除后遗留的场景侧车条目（加载时被忽略）」；
- weights_kept 明示「工具永不删权重」。
- 401（严格模式缺/错 admin token）→ 专用提示，通用错误回调不得覆盖。
"""
from pathlib import Path

from inferfabric import dashboard

JS_DIR = Path(dashboard._DASHBOARD_DIR) / "js"


def _src(name: str) -> str:
    return (JS_DIR / name).read_text(encoding="utf-8")


# ── 组装契约 ─────────────────────────────────────────────────────

def test_remove_entry_is_assembled():
    html = dashboard.get_html()
    # deploy 页模型表操作列有移除入口（deploy.js 内联进页面）
    assert 'data-action="model-remove"' in html


# ── deploy.js 移除流程契约 ───────────────────────────────────────

def test_deploy_js_remove_endpoint_and_401():
    src = _src("deploy.js")
    assert "admin/models/remove" in src
    assert "UI.adminHeaders" in src
    # 401 专用提示不被覆盖（终审 Important-1 同款）：通用错误回调先过
    # unauthorized 守卫
    assert src.count("err.unauthorized") >= 1
    assert "401" in src


def test_deploy_js_three_stage_confirm():
    src = _src("deploy.js")
    # 预览（无 confirmed）→ 报告展示 → confirmed:true 执行
    assert "confirmed" in src
    # blocked 时 purge 选项 + 二次预览，确认前必须重新预览
    assert "purge_pools" in src
    assert "重新预览" in src
    # 移除弹窗自建容器（cloud.js 属性浮窗同款动态 holder 模式）
    assert "depRemoveModal" in src


def test_deploy_js_running_three_state_copy():
    src = _src("deploy.js")
    assert "运行中" in src      # running=true（执行时将先停止服务）
    assert "未运行" in src      # running=false
    assert "状态未知" in src    # running=unknown（执行时将尝试停止）


def test_deploy_js_weights_and_scenario_copy():
    src = _src("deploy.js")
    assert "工具永不删权重" in src
    assert "加载时被忽略" in src


def test_deploy_js_inline_error_via_state():
    """执行失败内联报错走状态重渲染（st.error），不被重渲染抹掉（浏览器
    验收发现：先设 errEl 再 renderRemoveModal 会把错误清空）。"""
    src = _src("deploy.js")
    assert "st.error = '移除失败：' + msg" in src
    assert "st.error = null" in src


def test_deploy_js_no_inline_onclick():
    src = _src("deploy.js")
    assert "onclick=" not in src
