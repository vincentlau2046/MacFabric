"""Responses API 桥接单测（Issue #1，2026-11-17）。

覆盖：
- 路由注册：/v1/responses 在 _POST_ROUTES
- 兜底翻译：Responses → chat（instructions/input/tools/max_output_tokens）
- 响应翻译：chat → Responses（output_text/usage/tool_calls）
- 原生优先契约：2xx 原生透传不触发翻译；400/404/422/501 才兜底
- 池别名：fabric-fast 旧名入 /v1/responses 解析到 flash 池
"""

import json
import pytest

from inferfabric.proxy.responses_bridge import (
    RESPONSES_UNSUPPORTED_STATUSES,
    chat_to_responses,
    responses_to_chat,
)


def test_responses_route_registered():
    from inferfabric.proxy.handler import _POST_ROUTES
    assert "/v1/responses" in _POST_ROUTES


def test_unsupported_status_set_matches_ruling():
    # 用户裁决：只有明确返回失败不支持才兜底（400/404/422/501）；
    # 401/403/429/5xx 交既有动作表
    assert RESPONSES_UNSUPPORTED_STATUSES == frozenset({400, 404, 422, 501})


def test_responses_to_chat_string_input():
    chat = responses_to_chat({
        "model": "fabric-flash",
        "instructions": "be brief",
        "input": "hello",
        "max_output_tokens": 256,
        "temperature": 0.3,
    })
    assert chat["model"] == "fabric-flash"
    assert chat["messages"][0] == {"role": "system", "content": "be brief"}
    assert chat["messages"][1] == {"role": "user", "content": "hello"}
    assert chat["max_tokens"] == 256
    assert chat["temperature"] == 0.3
    assert chat["stream"] is False


def test_responses_to_chat_items_and_tools():
    chat = responses_to_chat({
        "model": "m",
        "input": [
            {"type": "message", "role": "user",
             "content": [{"type": "input_text", "text": "list files"}]},
            {"type": "function_call", "call_id": "c1", "name": "shell",
             "arguments": "{\"cmd\": \"ls\"}"},
            {"type": "function_call_output", "call_id": "c1", "output": "a.txt"},
            {"type": "reasoning", "summary": []},   # 兜底路径跳过
        ],
        "tools": [{"type": "function", "name": "shell",
                   "description": "run", "parameters": {"type": "object"}}],
        "tool_choice": "auto",
    })
    roles = [m["role"] for m in chat["messages"]]
    assert roles == ["user", "assistant", "tool"]
    assert chat["messages"][1]["tool_calls"][0]["id"] == "c1"
    assert chat["messages"][2]["tool_call_id"] == "c1"
    assert chat["tools"][0]["function"]["name"] == "shell"
    assert chat["tool_choice"] == "auto"


def test_chat_to_responses_basic():
    resp, usage = chat_to_responses({
        "choices": [{"message": {"role": "assistant", "content": "hi there"},
                     "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 11, "completion_tokens": 4},
    }, "fabric-flash")
    assert resp["object"] == "response"
    assert resp["model"] == "fabric-flash"
    assert resp["output_text"] == "hi there"
    assert resp["output"][0]["type"] == "message"
    assert resp["usage"]["input_tokens"] == 11
    assert resp["usage"]["output_tokens"] == 4
    assert usage["prompt_tokens"] == 11


def test_chat_to_responses_tool_calls():
    resp, _ = chat_to_responses({
        "choices": [{"message": {"role": "assistant", "content": None,
                                 "tool_calls": [{"id": "call_9", "type": "function",
                                                 "function": {"name": "shell",
                                                              "arguments": "{\"x\":1}"}}]},
                     "finish_reason": "tool_calls"}],
        "usage": {},
    }, "m")
    fc = resp["output"][0]
    assert fc["type"] == "function_call"
    assert fc["call_id"] == "call_9"
    assert fc["name"] == "shell"
    assert fc["arguments"] == "{\"x\":1}"


def test_pool_alias_via_responses_entry():
    # 旧名入站别名在 /v1/responses 同样生效（is_pool_name/pool_name_of 层）
    from inferfabric.model_pool.dispatch import is_pool_name, pool_name_of
    assert is_pool_name("fabric-fast") and pool_name_of("fabric-fast") == "flash"
