"""M2-T1 — packs 页组装与源码契约（计划 2026-11-19 Task 1）。

两层：
1. 组装契约：get_html() 产物必须真实装配 packs 页（nav/容器/JS 内联，
   占位符与加载失败替身不得残留）——dashboard/__init__.py 两个硬编码清单
   漏改会在此被钉住（Review Focus 2）。
2. 源码契约：packs.js 必须消费能力包全生命周期端点、走 UI.adminHeaders、
   事件委托（无 inline onclick）、卸载双段确认、真实安装阶段全集。
   安装阶段以 packs/installer.py INSTALL_STAGES + failed 为准（9+1 态），
   不得出现伪造下载百分比（status 无字节数，评审 2026-11-19）。
"""
from pathlib import Path

from inferfabric import dashboard

JS_DIR = Path(dashboard._DASHBOARD_DIR) / "js"


def _src(name: str) -> str:
    return (JS_DIR / name).read_text(encoding="utf-8")


# ── 组装契约 ─────────────────────────────────────────────────────

def test_packs_page_is_assembled():
    html = dashboard.get_html()
    # nav 项 + tab 容器真实存在
    assert 'data-tab="tab-packs"' in html
    assert 'id="tab-packs"' in html
    # JS 模块注册（两清单之一：JS_MODULES）
    assert "packs" in dashboard.JS_MODULES
    # packs.js 内容已内联（以端点常量为标记，防"占位符清空但 JS 缺失"）
    assert "admin/packs/catalog" in html
    # 占位符与加载失败替身不得残留（Review Focus 2：硬编码清单漏改的两种症状）
    assert "<!-- FRAGMENT:packs -->" not in html
    assert "<!-- JS:packs -->" not in html
    assert "Fragment packs 加载失败" not in html


# ── 源码契约 ─────────────────────────────────────────────────────

def test_packs_js_consumes_full_lifecycle():
    src = _src("packs.js")
    for endpoint in ("admin/packs/catalog", "admin/packs/status",
                     "admin/packs/install", "admin/packs/custom",
                     "admin/packs/uninstall-preview", "admin/packs/uninstall",
                     "admin/packs/policy"):
        assert endpoint in src, f"missing endpoint: {endpoint}"
    assert "UI.adminHeaders" in src
    assert "tabRenderers['tab-packs']" in src
    # 卸载双段确认（预览 → 显式 confirm → confirmed:true）
    assert "UI.confirm" in src
    assert "confirmed" in src
    # 401 专用提示不被覆盖（终审 Important-1）：每个弹通用错误 toast 的
    # 回调都必须先过 unauthorized 守卫 —— 5 个写回调 + loadCatalog（GET 路径
    # 曾漏网，401 专用提示被「目录加载失败」毫秒级覆盖）
    assert src.count("err.unauthorized") >= 6, \
        "every generic-error toast callback must guard err.unauthorized"


def test_packs_js_covers_real_install_stages():
    src = _src("packs.js")
    # packs/installer.py INSTALL_STAGES 全集 + failed（评审修订：不得漏态）
    for stage in ("preflight", "staging", "downloading", "verifying",
                  "preparing_runtime", "writing_config",
                  "isolated_healthcheck", "gateway_reload",
                  "installed", "failed"):
        assert stage in src, f"missing stage label: {stage}"
    # 无伪造下载进度（status 无字节数——百分比/MB 展示即违规）
    for banned in ("downloaded+", "total_bytes", "percent"):
        assert banned not in src


def test_packs_js_no_inline_onclick():
    src = _src("packs.js")
    assert "onclick=" not in src
