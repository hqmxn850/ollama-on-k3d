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
            default="Qwen3.8-27B-GGUF, gemma4-it:e4b",
            description="並列問い合わせを行うモデル名のカンマ区切りリスト"
        )
        OLLAMA_URL: str = Field(
            default="http://lemonade.lemonade.svc.cluster.local:11434",
            description="Lemonade (Ollama 互換 API) サービス URL"
        )
        OGA_URL: str = Field(
            default="",
            description="FastFlowLM (OpenAI 互換 API) サービス URL (未設定時は環境変数 OPENAI_API_BASE_URLS を使用)"
        )
        TIMEOUT_SECONDS: int = Field(
            default=300,
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
            url = "http://lemonade.lemonade.svc.cluster.local:11434"

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

    async def pipe(self, body: dict, __user__: dict = None, **kwargs) -> Union[str, AsyncGenerator[str, None]]:
        messages = body.get("messages", [])
        if not messages:
            return "メッセージが指定されていません。"

        models = [m.strip() for m in self.valves.MODELS.split(",") if m.strip()]
        if not models:
            return "モデルが設定されていません。"

        # クラスタ内サービス URL 解決 (環境変数を優先、Valves はフォールバック)
        env_ollama = (os.environ.get("OLLAMA_BASE_URLS") or "").strip()
        if not env_ollama.startswith("http"):
            env_ollama = self.valves.OLLAMA_URL or "http://lemonade.lemonade.svc.cluster.local:11434"
        ollama_url = env_ollama

        env_oga = (os.environ.get("OPENAI_API_BASE_URLS") or "").strip()
        if not env_oga.startswith("http"):
            env_oga = self.valves.OGA_URL or ""
        oga_url = env_oga

        async with aiohttp.ClientSession() as session:
            tasks = []
            for model in models:
                # モデル名に応じてルーティング判定（NPU / OGA 判定: 0.6b, e4b, e2b, gemma4, npu, flm 等）
                m_lower = model.lower()
                if any(k in m_lower for k in ["0.6b", "e4b", "e2b", "gemma4", "npu", "flm"]):
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
