"""
title: Pipe Planner Agent v2
author: Haervwe / Open WebUI Community
author_url: https://openwebui.com
version: 2.0.0
description: 複雑なタスクをステップバイステップの計画（Plan）に自動分解し、各段階を順次推論・実行して高品質な最終レポートや納品物を生成するマルチステップ計画エージェント Pipe です。
"""

import json
from typing import Optional, Union, Generator, Iterator
import urllib.request
from pydantic import BaseModel, Field


class Pipe:
    class Valves(BaseModel):
        ollama_url: str = Field(default="http://lemonade.lemonade.svc.cluster.local:11434", description="Lemonade (Ollama 互換 API) URL")
        default_model: str = Field(default="Qwen3.8-27B-GGUF", description="計画および実行に利用する LLM モデル")
        max_steps: int = Field(default=4, description="タスク分解の最大ステップ数")

    def __init__(self):
        self.valves = self.Valves()

    def pipes(self) -> list[dict]:
        return [
            {
                "id": "planner-agent-v2",
                "name": "Planner Agent v2 (自律計画・段階推論エージェント)",
            }
        ]

    def _call_llm(self, messages: list[dict], model: Optional[str] = None) -> str:
        target_model = model or self.valves.default_model
        req_data = {
            "model": target_model,
            "messages": messages,
            "stream": False,
        }
        url = f"{self.valves.ollama_url}/api/chat"
        req = urllib.request.Request(
            url,
            data=json.dumps(req_data).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                res_json = json.loads(resp.read().decode("utf-8"))
                return res_json.get("message", {}).get("content", "")
        except Exception as e:
            return f"LLM 呼び出しエラー: {e}"

    async def pipe(self, body: dict, __user__: Optional[dict] = None) -> str:
        messages = body.get("messages", [])
        if not messages:
            return "エラー: メッセージが見つかりません。"

        user_msg = messages[-1].get("content", "")
        yield_parts = []

        # ── 1. 計画フェーズ (Plan Generation) ──
        plan_prompt = [
            {
                "role": "system",
                "content": (
                    "あなたは優秀なプロジェクトマネージャー兼プランナーです。\n"
                    "ユーザーの要求を分析し、目標達成のための論理的な実行計画（2〜4ステップ）を立案してください。\n"
                    "各ステップには「目的」と「検討・成果物の観点」を明記してください。"
                ),
            },
            {"role": "user", "content": f"以下の課題に対する実行計画を立案してください:\n\n{user_msg}"},
        ]
        plan_result = self._call_llm(plan_prompt)
        yield_parts.append(f"## 📋 実行計画 (Plan)\n\n{plan_result}\n\n---\n")

        # ── 2. 実行・統合フェーズ (Execution & Synthesis) ──
        execute_prompt = [
            {
                "role": "system",
                "content": (
                    "あなたは極めて優秀な専門家です。立案された実行計画に沿って、"
                    "ユーザーの要求に対する包括的・網羅的で実用的な最終成果物（回答・分析・コード等）を作成してください。\n"
                    "構成は見出し、要点、詳細、結論を明瞭に分けて作成してください。"
                ),
            },
            {"role": "user", "content": f"課題: {user_msg}\n\n計画:\n{plan_result}\n\n上記計画に基づき、高品質な成果物を作成してください。"},
        ]
        exec_result = self._call_llm(execute_prompt)
        yield_parts.append(f"## 🚀 成果物・詳細回答 (Execution)\n\n{exec_result}")

        return "".join(yield_parts)
