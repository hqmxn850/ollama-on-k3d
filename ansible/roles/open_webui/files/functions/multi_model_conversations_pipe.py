"""
title: Multi Model Conversations Pipe
author: Open WebUI
version: 1.0.0
description: 複数のモデルに並列でリクエストを送信し、回答を比較・表示するパイプライン
"""

from typing import List, Union, Generator, Iterator, AsyncGenerator
from pydantic import BaseModel, Field
import aiohttp
import asyncio
import json
import os

class Pipe:
    class Valves(BaseModel):
        MODELS: str = Field(
            default="FieldMouse-AI/qwen3.8:27B,qwen3:0.6b",
            description="並列問い合わせを行うモデル名のカンマ区切りリスト"
        )
        TIMEOUT_SECONDS: int = Field(
            default=60,
            description="各モデルのリクエストタイムアウト（秒）"
        )

    def __init__(self):
        self.type = "pipe"
        self.id = "multi_model_pipe"
        self.name = "Multi Model Conversations"
        self.valves = self.Valves()

    def pipes(self) -> List[dict]:
        return [
            {
                "id": f"{self.id}",
                "name": f"{self.name} (Parallel)",
                "description": "複数のモデルに並列で質問し、回答を比較します。"
            }
        ]

    async def _query_model(self, session: aiohttp.ClientSession, base_url: str, model: str, messages: list) -> str:
        payload = {
            "model": model,
            "messages": messages,
            "stream": False
        }
        url = f"{base_url.rstrip('/')}/chat/completions"
        try:
            async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=self.valves.TIMEOUT_SECONDS)) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    choices = data.get("choices", [])
                    if choices:
                        return choices[0].get("message", {}).get("content", "")
                    return "応答が空でした。"
                else:
                    text = await resp.text()
                    return f"エラー (HTTP {resp.status}): {text[:200]}"
        except asyncio.TimeoutError:
            return f"タイムアウト ({self.valves.TIMEOUT_SECONDS}秒)"
        except Exception as e:
            return f"通信エラー: {str(e)}"

    async def pipe(self, body: dict) -> Union[str, AsyncGenerator[str, None]]:
        messages = body.get("messages", [])
        if not messages:
            return "メッセージが指定されていません。"

        models = [m.strip() for m in self.valves.MODELS.split(",") if m.strip()]
        if not models:
            return "モデルが設定されていません。"

        # クラスタ内サービスURL
        # Ollama は /v1/chat/completions, OGA は /v1/chat/completions をサポート
        ollama_url = os.environ.get("OLLAMA_BASE_URL", "http://ollama.ollama.svc.cluster.local:11434/v1")
        oga_url = os.environ.get("OGA_BASE_URL", "http://oga.oga.svc.cluster.local:8000/v1")

        async with aiohttp.ClientSession() as session:
            tasks = []
            for model in models:
                # モデル名に応じてルーティング判定（qwen3:0.6b や npu は OGA, その他は Ollama）
                if "0.6b" in model.lower() or "npu" in model.lower() or "flm" in model.lower():
                    endpoint = oga_url
                else:
                    endpoint = ollama_url
                tasks.append(self._query_model(session, endpoint, model, messages))

            results = await asyncio.gather(*tasks, return_exceptions=True)

        output = ["### 🤖 複数モデル並列回答比較\n"]
        for model, res in zip(models, results):
            if isinstance(res, Exception):
                ans = f"例外発生: {str(res)}"
            else:
                ans = str(res)
            output.append(f"#### 🔹 モデル: `{model}`\n\n{ans}\n\n---\n")

        return "\n".join(output)
