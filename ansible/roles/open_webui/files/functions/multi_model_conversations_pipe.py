"""
title: Multi Model Conversations Pipe
author: Open WebUI
version: 1.0.1
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
            default="FieldMouse-AI/qwen3.8:27B, qwen3:0.6b",
            description="並列問い合わせを行うモデル名のカンマ区切りリスト"
        )
        OLLAMA_URL: str = Field(
            default="http://ollama.ollama.svc.cluster.local:11434",
            description="Ollama サービス URL"
        )
        OGA_URL: str = Field(
            default="http://oga.oga.svc.cluster.local:8000/v1",
            description="OGA / NPU (FastFlowLM) サービス URL"
        )
        TIMEOUT_SECONDS: int = Field(
            default=180,
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
        # URL 組み立てと絶対URLチェック
        url = (base_url or "").strip().rstrip('/')
        if not url.startswith("http://") and not url.startswith("https://"):
            url = "http://ollama.ollama.svc.cluster.local:11434"

        # /v1/chat/completions エンドポイントの保証
        if url.endswith("/v1"):
            api_endpoint = f"{url}/chat/completions"
        else:
            api_endpoint = f"{url}/v1/chat/completions"

        payload = {
            "model": model,
            "messages": messages,
            "stream": False
        }
        headers = {"Content-Type": "application/json"}
        try:
            async with session.post(api_endpoint, json=payload, headers=headers, timeout=aiohttp.ClientTimeout(total=self.valves.TIMEOUT_SECONDS)) as resp:
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

        # クラスタ内サービスURL解決 (環境変数からのフォールバック)
        env_ollama = os.environ.get("OLLAMA_BASE_URLS") or ""
        if not env_ollama.startswith("http"):
            env_ollama = "http://ollama.ollama.svc.cluster.local:11434"
        ollama_url = self.valves.OLLAMA_URL or env_ollama

        env_oga = os.environ.get("OPENAI_API_BASE_URLS") or ""
        if not env_oga.startswith("http"):
            env_oga = "http://oga.oga.svc.cluster.local:8000/v1"
        oga_url = self.valves.OGA_URL or env_oga

        async with aiohttp.ClientSession() as session:
            tasks = []
            for model in models:
                # モデル名に応じてルーティング判定（0.6b や npu, flm は OGA, その他は Ollama）
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
