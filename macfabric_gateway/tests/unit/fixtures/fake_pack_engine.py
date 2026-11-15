#!/usr/bin/env python3
"""能力包端到端测试用假引擎（Task 12 fixture）。

最小 OpenAI 兼容假 llama-server：解析 --port（其余 argv 忽略 — 真引擎参数
由 llama_cpp 进程管理器传递），GET /health → 200，POST /v1/chat/completions
→ 固定回复（回显 model 别名）。仅用于测试，非产品代码。
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


def _port_from_argv(argv):
    for i, a in enumerate(argv):
        if a == "--port" and i + 1 < len(argv):
            return int(argv[i + 1])
        if a.startswith("--port="):
            return int(a.split("=", 1)[1])
    return 18080


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
            model = req.get("model", "fake")
        except ValueError:
            model = "fake"
        body = json.dumps({
            "id": "chatcmpl-fake",
            "object": "chat.completion",
            "model": model,
            "choices": [{"index": 0, "message": {
                "role": "assistant", "content": "fake-pack-reply"},
                "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1,
                      "total_tokens": 2},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    port = _port_from_argv(sys.argv[1:])
    server = HTTPServer(("127.0.0.1", port), Handler)
    server.serve_forever()
