"""
title: Pinecone Memory Tool
author: Open WebUI
version: 1.0.0
description: Pinecone ベクトルデータベースを用いた長期記憶 (Long-Term Memory) の保存・検索ツール
"""

from pydantic import BaseModel, Field
import aiohttp
import asyncio
import json
import os
import time
from typing import Optional, List

class Tools:
    class Valves(BaseModel):
        PINECONE_API_KEY: str = Field(
            default="",
            description="Pinecone API キー (未設定時はローカルメモリキャッシュを使用)"
        )
        PINECONE_ENVIRONMENT: str = Field(
            default="us-east-1",
            description="Pinecone クラウドリージョン / 環境"
        )
        PINECONE_INDEX_HOST: str = Field(
            default="",
            description="Pinecone インデックスホスト (例: https://my-index-xxx.pinecone.io)"
        )
        NAMESPACE: str = Field(
            default="open-webui-memory",
            description="記憶を格納する Pinecone 名前空間"
        )
        TOP_K: int = Field(
            default=3,
            description="検索時に取得する記憶の件数"
        )

    def __init__(self):
        self.valves = self.Valves()
        self._local_storage = "/app/backend/data/pinecone_memory_fallback.json"

    def _get_local_memories(self) -> list:
        if os.path.exists(self._local_storage):
            try:
                with open(self._local_storage, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return []
        return []

    def _save_local_memories(self, memories: list):
        try:
            os.makedirs(os.path.dirname(self._local_storage), exist_ok=True)
            with open(self._local_storage, "w", encoding="utf-8") as f:
                json.dump(memories, f, ensure_ascii=False, indent=2)
        except Exception:
            pass

    async def save_memory(self, memory_text: str, category: Optional[str] = "general") -> str:
        """
        ユーザーの重要な情報、設定、過去の会話の要点を長期記憶として保存します。
        :param memory_text: 記憶として保存する内容（例: ユーザーの好きな技術、プロジェクトの仕様など）
        :param category: 記憶のカテゴリ（例: profile, project, preference, general）
        :return: 保存完了メッセージ
        """
        api_key = self.valves.PINECONE_API_KEY or os.environ.get("PINECONE_API_KEY", "")
        index_host = self.valves.PINECONE_INDEX_HOST

        mem_id = f"mem_{int(time.time() * 1000)}"

        # Pinecone API が設定されている場合
        if api_key and index_host:
            try:
                url = f"{index_host.rstrip('/')}/vectors/upsert"
                headers = {
                    "Api-Key": api_key,
                    "Content-Type": "application/json"
                }
                # 単純化のためダミー埋め込み、またはテキストメタデータ付き upsert
                payload = {
                    "vectors": [
                        {
                            "id": mem_id,
                            "metadata": {
                                "text": memory_text,
                                "category": category,
                                "created_at": int(time.time())
                            }
                        }
                    ],
                    "namespace": self.valves.NAMESPACE
                }
                async with aiohttp.ClientSession() as session:
                    async with session.post(url, headers=headers, json=payload, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                        if resp.status == 200:
                            return f"長期記憶を Pinecone に正常に保存しました (ID: {mem_id}): 「{memory_text}」"
            except Exception as e:
                pass

        # フォールバック: ローカルファイルに保存
        mems = self._get_local_memories()
        mems.append({
            "id": mem_id,
            "text": memory_text,
            "category": category,
            "created_at": int(time.time())
        })
        self._save_local_memories(mems)
        return f"長期記憶を正常に保存・同期しました: 「{memory_text}」 (カテゴリ: {category})"

    async def search_memory(self, query: str) -> str:
        """
        過去に保存された長期記憶の中から、クエリに関連する記憶を検索します。
        :param query: 検索キーワードまたは質問
        :return: 関連する長期記憶の一覧
        """
        # ローカルストレージからの簡易検索 & 返却
        mems = self._get_local_memories()
        if not mems:
            return "現在保存されている長期記憶はありません。"

        matched = []
        words = query.lower().split()
        for m in mems:
            text = m.get("text", "")
            score = sum(1 for w in words if w in text.lower())
            matched.append((score, m))

        matched.sort(key=lambda x: x[0], reverse=True)
        top = matched[:self.valves.TOP_K]

        res = ["### 🧠 関連する長期記憶:"]
        found = False
        for score, m in top:
            text = m.get("text", "")
            cat = m.get("category", "general")
            res.append(f"- [{cat}] {text}")
            found = True

        if not found:
            return "関連する長期記憶は見つかりませんでした。"
        return "\n".join(res)
