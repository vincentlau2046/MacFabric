"""运行时准备 + 隔离健康检查 — PK4 真包链路缺口（2026-11-16 沙箱取证）。

取证事实：installed 包的 runtime/engine 是 gzip 原包（16908908 字节，
`file` 判 gzip compressed data）——installer 的 prepare_runtime/健康检查
钩子生产从未接线（默认 noop），fake 测试的"引擎"本就是现成脚本，全绿
网外。契约：
- prepare_runtime(pack_dir, manifest)：按 runtime_template 分发；
  llama-cpp-macos-arm64-v1 = 安全解包 runtime/engine 的 tar.gz（拒绝对
  路径/.. 成员）、摊平顶层目录、llama-server → runtime/engine（chmod 755，
  rpath @loader_path 要求二进制与 dylib 同目录）、删除压缩包。
- 未知模板 → RuntimeError（安装事务在 preparing_runtime 阶段诚实失败）。
- healthcheck_llama_cpp(pack_dir, manifest)：真拉起 engine（-m 包内模型
  --alias model_id），轮询 /health，探活后收割子进程；超时抛错。
"""

import io
import tarfile

import pytest

from inferfabric.packs.runtime_prep import (
    healthcheck_llama_cpp, prepare_runtime)
from tests_fixtures_packs import MINIMAL_MANIFEST_YAML
from inferfabric.packs.schema import parse_manifest

MANIFEST = parse_manifest(MINIMAL_MANIFEST_YAML)


def _make_gz(tmp_path, members, top="llama-b12361"):
    """构造假 llama.cpp 发行包：{top}/{name} → (data, mode)。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, (data, mode) in members.items():
            ti = tarfile.TarInfo(f"{top}/{name}")
            ti.size = len(data)
            ti.mode = mode
            tf.addfile(ti, io.BytesIO(data))
    out = tmp_path / "runtime" / "engine"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(buf.getvalue())
    return out


FAKE_SERVER = b"#!/bin/sh\necho llama-server-stub\n"
FAKE_DYLIB = b"\xcf\xfa\xed\xfe-fake-mach-o"


def test_prepare_extracts_and_flattens(tmp_path):
    src = _make_gz(tmp_path, {
        "llama-server": (FAKE_SERVER, 0o755),
        "libggml.dylib": (FAKE_DYLIB, 0o644),
    })
    prepare_runtime(tmp_path, MANIFEST)
    engine = tmp_path / "runtime" / "engine"
    assert engine.read_bytes() == FAKE_SERVER          # llama-server → engine
    assert engine.stat().st_mode & 0o111               # 可执行
    assert (tmp_path / "runtime" / "libggml.dylib").read_bytes() == FAKE_DYLIB
    assert src.read_bytes() == FAKE_SERVER             # engine 位被 entry 覆盖
    assert not list((tmp_path / "runtime").glob("_prep-*"))  # 无残留临时目录


def test_prepare_handles_dylib_symlinks(tmp_path):
    # 真实发行包取证：libggml.1.dylib → libggml.1.0.0.dylib（符号链接）；
    # 链接必须原样保留且不因 chmod 时序崩（链接目标可能后到）
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, data, mode in [("libggml.1.0.0.dylib", FAKE_DYLIB, 0o644),
                                 ("llama-server", FAKE_SERVER, 0o755)]:
            ti = tarfile.TarInfo(f"llama-b12361/{name}")
            ti.size = len(data); ti.mode = mode
            tf.addfile(ti, io.BytesIO(data))
        ln = tarfile.TarInfo("llama-b12361/libggml.1.dylib")
        ln.type = tarfile.SYMTYPE; ln.linkname = "libggml.1.0.0.dylib"
        tf.addfile(ln)
    d = tmp_path / "runtime"; d.mkdir(parents=True)
    (d / "engine").write_bytes(buf.getvalue())
    prepare_runtime(tmp_path, MANIFEST)
    import os
    assert (tmp_path / "runtime" / "libggml.1.dylib").is_symlink()
    assert (tmp_path / "runtime" / "libggml.1.0.0.dylib").read_bytes() == FAKE_DYLIB
    assert (tmp_path / "runtime" / "engine").read_bytes() == FAKE_SERVER


def test_prepare_rejects_path_traversal(tmp_path):
    src = _make_gz(tmp_path, {"../evil.sh": (b"boom", 0o755)})
    with pytest.raises(RuntimeError, match="unsafe"):
        prepare_runtime(tmp_path, MANIFEST)
    assert not (tmp_path.parent / "evil.sh").exists() \
        and not (tmp_path / "evil.sh").exists()
    # 失败不破坏原包（事务 fail 兜底删除，这里只要求不越界写）


def test_prepare_rejects_non_gzip(tmp_path):
    d = tmp_path / "runtime"
    d.mkdir(parents=True)
    (d / "engine").write_bytes(b"definitely not gzip")
    with pytest.raises(RuntimeError, match="not a gzip"):
        prepare_runtime(tmp_path, MANIFEST)


def test_prepare_unknown_template(tmp_path):
    import dataclasses
    m = dataclasses.replace(MANIFEST, runtime_template="nope-v9")
    with pytest.raises(RuntimeError, match="runtime_template_not_implemented"):
        prepare_runtime(tmp_path, m)


def test_healthcheck_spawns_and_kills_engine(tmp_path):
    # 假引擎：加载即监听 /health 200 — 健康检查通过并收割子进程
    d = tmp_path / "runtime"
    d.mkdir(parents=True)
    (d / "engine").write_text(
        "#!/usr/bin/env python3\n"
        "import http.server, threading, sys, time\n"
        "class H(http.server.BaseHTTPRequestHandler):\n"
        "    def do_GET(self):\n"
        "        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')\n"
        "    def log_message(self, *a): pass\n"
        "port = sys.argv[sys.argv.index('--port') + 1]\n"
        "srv = http.server.HTTPServer(('127.0.0.1', int(port)), H)\n"
        "srv.serve_forever()\n")
    (d / "engine").chmod(0o755)
    (tmp_path / "models").mkdir()
    (tmp_path / "models" / "model").write_bytes(b"M")
    healthcheck_llama_cpp(tmp_path, MANIFEST, timeout_s=20)
    # 引擎进程已被收割：无残留监听（端口池探测的端口不可知，靠进程表验证）
    import subprocess
    out = subprocess.run(["pgrep", "-f", "runtime/engine"], capture_output=True)
    assert out.returncode != 0, "healthcheck 后引擎进程未被收割"


def test_healthcheck_timeout_raises(tmp_path):
    # 假引擎：监听但 /health 恒 503（模型加载不动）→ 超时抛错 + 收割
    d = tmp_path / "runtime"
    d.mkdir(parents=True)
    (d / "engine").write_text(
        "#!/usr/bin/env python3\n"
        "import http.server, sys\n"
        "class H(http.server.BaseHTTPRequestHandler):\n"
        "    def do_GET(self):\n"
        "        self.send_response(503); self.end_headers()\n"
        "    def log_message(self, *a): pass\n"
        "http.server.HTTPServer(('127.0.0.1', int(sys.argv[2])), H).serve_forever()\n")
    (d / "engine").chmod(0o755)
    (tmp_path / "models").mkdir()
    (tmp_path / "models" / "model").write_bytes(b"M")
    with pytest.raises(RuntimeError, match="healthcheck"):
        healthcheck_llama_cpp(tmp_path, MANIFEST, timeout_s=3)
    import subprocess
    out = subprocess.run(["pgrep", "-f", "runtime/engine"], capture_output=True)
    assert out.returncode != 0, "超时后引擎进程未被收割"


def test_pack_manager_wires_real_hooks(tmp_path):
    from inferfabric.proxy.pack_handlers import PackManager
    from inferfabric.packs.runtime_prep import (
        prepare_runtime as real_prep, healthcheck_llama_cpp as real_hc)
    import yaml as yaml_mod
    from inferfabric.packs.schema import parse_manifest
    import hashlib
    m = parse_manifest(MINIMAL_MANIFEST_YAML).to_dict()
    m["resources"]["download_mb"] = 1
    m["resources"]["disk_mb"] = 1
    m["artifacts"] = [
        {"id": "model", "kind": "model", "source": "https://x/m",
         "sha256": hashlib.sha256(b"M").hexdigest()},
        {"id": "engine", "kind": "runtime", "source": "https://x/e",
         "sha256": hashlib.sha256(b"E").hexdigest()}]
    cat = tmp_path / "cat.yaml"
    cat.write_text(yaml_mod.safe_dump({"packs": [{
        "pack_id": m["pack_id"], "display_name": "T", "summary": "s",
        "tags": [], "risk_level": "verified", "builtin": False,
        "manifest": m}]}, sort_keys=False))
    pm = PackManager(root=tmp_path / "packs", models_d=tmp_path / "models.d",
                     catalog_path=cat, fetcher=object(),
                     reload_gateway=lambda: None)
    assert pm.installer._prepare_runtime is real_prep
    assert pm.installer._run_healthcheck is real_hc
