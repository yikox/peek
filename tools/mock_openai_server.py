#!/usr/bin/env python3
"""最小 OpenAI 兼容服务，用于本地端到端验证。

覆盖的场景：
  GET  /v1/models              列出模型（含免费/付费/应被过滤的 embedding）
  POST /v1/chat/completions    正常翻译
       model 含 nokey      → 401，模拟 Key 无效
       model 含 reasoning  → 200 但只有 reasoning_content，模拟推理模型
       model 含 broken     → 404，模拟模型下线
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 18923

MODELS = [
    {
        "id": "mock/mock-fast",
        "name": "Mock Fast (free)",
        "context_length": 128000,
        "pricing": {"prompt": "0", "completion": "0"},
        "architecture": {"output_modalities": ["text"]},
    },
    {
        "id": "mock/mock-paid",
        "name": "Mock Paid",
        "context_length": 32000,
        "pricing": {"prompt": "0.0000005", "completion": "0.0000015"},
        "architecture": {"output_modalities": ["text"]},
    },
    {
        "id": "mock/mock-reasoning",
        "name": "Mock Reasoning (free)",
        "context_length": 100000,
        "pricing": {"prompt": "0", "completion": "0"},
        "architecture": {"output_modalities": ["text"]},
    },
    {
        "id": "mock/mock-nokey",
        "name": "Mock No Key (free)",
        "context_length": 8000,
        "pricing": {"prompt": "0", "completion": "0"},
        "architecture": {"output_modalities": ["text"]},
    },
    {
        # 这个应该被 ModelCatalog 的命名过滤剔除
        "id": "mock/text-embedding-3-large",
        "name": "Embedding Large",
        "context_length": 8191,
        "pricing": {"prompt": "0", "completion": "0"},
        "architecture": {"output_modalities": ["text"]},
    },
]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._send(200, {"object": "list", "data": MODELS})
            print("[server] GET /models", flush=True)
        else:
            self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
        except Exception:
            req = {}

        model = req.get("model", "?")
        messages = req.get("messages", [])
        user = ""
        for m in messages:
            if m.get("role") == "user":
                user = m.get("content", "")

        print(f"[server] POST chat model={model} max_tokens={req.get('max_tokens')} user_len={len(user)}", flush=True)

        if "nokey" in model:
            self._send(401, {"error": {"message": "Invalid API key provided", "code": 401}})
            return
        if "broken" in model:
            self._send(404, {"error": {"message": "No endpoints found for this model", "code": 404}})
            return
        if "reasoning" in model:
            self._send(200, {
                "id": "chatcmpl-local",
                "object": "chat.completion",
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": "", "reasoning_content": "让我想想这句话怎么翻……"},
                    "finish_reason": "stop",
                }],
            })
            return

        # max_tokens=1 的探测请求只回 1 个字符，模拟真实截断
        content = "一个人" if req.get("max_tokens") == 1 else "一个人的性格就是他的命运。"
        self._send(200, {
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "model": model,
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": len(user), "completion_tokens": 16},
        })

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"listening on http://127.0.0.1:{PORT}", flush=True)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
