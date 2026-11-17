"""防回归 guard：测试套件不得依赖外网（次级 1 · spec 2026-11-17-batch4-jobs-infra.md）。

现状摸底（2026-11-17）：全部单测走本机回环假服务（HTTPServer 127.0.0.1）
或 monkeypatch，外网 URL 字面量仅出现在占位字符串/文档注释中。
本 guard 把「测试不碰外网」从约定升级为可执行契约：
凡新增外网字面量（非常见占位主机）即 fail，逼显式归类。
"""
import re
from pathlib import Path

TESTS = Path(__file__).parent

# 允许的占位/文档主机（不发起真实连接）；新增白名单条目需在 PR 说明理由
ALLOWED_HOSTS = {
    "127.0.0.1", "localhost", "0.0.0.0",
    "a", "b", "x", "x.cn",
    "example.com", "evil.example",
    "github.com", "modelscope.cn",
}

URL_RE = re.compile("https?://([^/:\" )]+)")

def test_no_external_network_literals():
    offenders = []
    for py in sorted(TESTS.rglob("*.py")):  # 自检用例外：guard 文件自身
        rel = py.relative_to(TESTS)
        if py.name == "test_no_network_dependency.py":
            continue  # 自检字符串会被自身扫描误伤
        for i, line in enumerate(py.read_text(encoding="utf-8").splitlines(), 1):
            for m in URL_RE.finditer(line):
                host = m.group(1).strip().lower()
                if host not in ALLOWED_HOSTS:
                    offenders.append(f"{rel}:{i}: {host} ({line.strip()[:80]})")
    assert not offenders, (
        "测试代码出现非白名单外网字面量 — 若是占位/文档用途请加入白名单并说明；"
        "若是真实调用请改为本机回环假服务。\n" + "\n".join(offenders)
    )

def test_guard_self_check():
    """guard 自身解析逻辑有效：已知外网主机必被抓到。"""
    line = 'url = "https://unknown-external-host.test/api"'
    m = URL_RE.search(line)
    assert m and m.group(1) == "unknown-external-host.test"
