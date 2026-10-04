"""
title: Perplexica Search Tool
author: Open WebUI
version: 1.0.0
description: Perplexica AI 検索エンジン (または高精度フォールバック検索) を用いた引用付き深層 Web 検索ツール
"""

from pydantic import BaseModel, Field
import aiohttp
import asyncio
import json
from typing import Optional

try:
    from ddgs import DDGS
except ImportError:
    DDGS = None

class Tools:
    class Valves(BaseModel):
        PERPLEXICA_API_URL: str = Field(
            default="http://perplexica.searxng.svc.cluster.local:3000/api/search",
            description="Perplexica API のエンドポイント URL (利用可能な場合)"
        )
        SEARCH_FOCUS: str = Field(
            default="webSearch",
            description="検索フォーカス (webSearch, academicSearch, writingAssistant, wolframAlpha, youtubeSearch, redditSearch)"
        )
        FALLBACK_REGION: str = Field(
            default="jp-jp",
            description="フォールバック検索時の地域コード (例: jp-jp)"
        )
        MAX_RESULTS: int = Field(
            default=5,
            description="取得する最大結果件数"
        )

    def __init__(self):
        self.valves = self.Valves()

    async def search(self, query: str, focus_mode: Optional[str] = None) -> str:
        """
        Perplexica または Web 検索エンジンを使用して最新情報を深層検索し、要約と引用ソースを返します。
        :param query: 検索クエリや質問内容
        :param focus_mode: 検索フォーカス (webSearch, academicSearch 等。未指定時はデフォルト)
        :return: 引用付きの検索結果テキスト
        """
        focus = focus_mode or self.valves.SEARCH_FOCUS
        url = self.valves.PERPLEXICA_API_URL

        # 1. Perplexica API 呼び出しを試行
        try:
            payload = {
                "chatModel": {"provider": "custom_openai", "model": "default"},
                "embeddingModel": {"provider": "custom_openai", "model": "default"},
                "optimizationMode": "balanced",
                "focusMode": focus,
                "query": query,
                "history": []
            }
            async with aiohttp.ClientSession() as session:
                async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        message = data.get("message", "")
                        sources = data.get("sources", [])
                        out = [f"### 🔍 Perplexica 検索結果\n{message}\n\n### 📚 引用・情報源:"]
                        for i, s in enumerate(sources, 1):
                            title = s.get("metadata", {}).get("title", f"Source {i}")
                            link = s.get("metadata", {}).get("url", "")
                            out.append(f"- [{i}] [{title}]({link})")
                        return "\n".join(out)
        except Exception:
            # Perplexica API が未稼働または接続できない場合は DuckDuckGo にフォールバック
            pass

        # 2. 高精度フォールバック検索 (DDGS)
        if DDGS is not None:
            try:
                with DDGS() as ddgs:
                    results = []
                    try:
                        results = list(ddgs.text(query, region=self.valves.FALLBACK_REGION, max_results=self.valves.MAX_RESULTS))
                    except Exception:
                        results = []
                    if not results:
                        results = list(ddgs.text(query, max_results=self.valves.MAX_RESULTS))

                    if not results:
                        return f"「{query}」に関する検索結果は見つかりませんでした。"

                    out = [f"### 🔍 Web 検索結果 (引用・要約)\nクエリ: `{query}`\n"]
                    for i, r in enumerate(results, 1):
                        title = r.get("title", "")
                        href = r.get("href", "")
                        body = r.get("body", "")
                        out.append(f"**[{i}] [{title}]({href})**\n> {body}\n")
                    return "\n".join(out)
            except Exception as e:
                return f"フォールバック検索中にエラーが発生しました: {str(e)}"

        return "検索プロバイダに接続できませんでした。"
