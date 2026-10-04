"""
title: Pinecone Memory Filter
author: Open WebUI
version: 1.0.0
description: ユーザー入力に関連する長期記憶 (Pinecone / Local Memory) を自動検索し、モデルのシステムコンテキストに自動注入するフィルター
"""

from pydantic import BaseModel, Field
from typing import Optional, List
import json
import os

class Filter:
    class Valves(BaseModel):
        ENABLE_AUTO_RECALL: bool = Field(
            default=True,
            description="長期記憶の自動想起とコンテキスト注入を有効化"
        )
        MEMORY_FILE_PATH: str = Field(
            default="/app/backend/data/pinecone_memory_fallback.json",
            description="ローカル記憶ストレージのパス"
        )
        MAX_RECALLED_MEMORIES: int = Field(
            default=3,
            description="自動注入する記憶の最大件数"
        )

    def __init__(self):
        self.valves = self.Valves()

    def _get_relevant_memories(self, query: str) -> List[str]:
        path = self.valves.MEMORY_FILE_PATH
        if not os.path.exists(path):
            return []
        try:
            with open(path, "r", encoding="utf-8") as f:
                mems = json.load(f)
            words = [w.lower() for w in query.split() if len(w) > 1]
            if not words:
                return []
            
            scored = []
            for m in mems:
                txt = m.get("text", "")
                score = sum(1 for w in words if w in txt.lower())
                if score > 0:
                    scored.append((score, txt))
            
            scored.sort(key=lambda x: x[0], reverse=True)
            return [t for _, t in scored[:self.valves.MAX_RECALLED_MEMORIES]]
        except Exception:
            return []

    async def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        if not self.valves.ENABLE_AUTO_RECALL:
            return body

        messages = body.get("messages", [])
        if not messages:
            return body

        # 最新のユーザーメッセージを取得
        last_user_msg = None
        for m in reversed(messages):
            if m.get("role") == "user":
                last_user_msg = m.get("content", "")
                break

        if not last_user_msg or not isinstance(last_user_msg, str):
            return body

        recalled = self._get_relevant_memories(last_user_msg)
        if recalled:
            mem_text = "\n".join([f"- {r}" for r in recalled])
            injection = f"\n\n[長期記憶 (Long-Term Memory)]:\n{mem_text}\n必要に応じて上記情報を踏まえて回答してください。\n"
            
            # システムメッセージがあれば追記、なければ先頭に追加
            if messages[0].get("role") == "system":
                messages[0]["content"] += injection
            else:
                messages.insert(0, {
                    "role": "system",
                    "content": f"あなたは親切なAIアシスタントです。{injection}"
                })
            body["messages"] = messages

        return body
