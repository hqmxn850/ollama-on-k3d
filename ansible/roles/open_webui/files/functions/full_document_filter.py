"""
title: Full Document Filter
author: Open WebUI Community
author_url: https://openwebui.com
version: 1.0.0
description: 添付ドキュメントの断片化（チャンク分割）を防ぎ、ドキュメント全文をコンテキストに完全注入して高精度な全体レビュー・分析を可能にします。
"""

from typing import Optional
from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0, description="フィルター実行優先度")
        max_chars: int = Field(default=100000, description="注入する最大文字数")
        enabled: bool = Field(default=True, description="全文注入の有効化")

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        if not self.valves.enabled:
            return body

        messages = body.get("messages", [])
        if not messages:
            return body

        files = body.get("files", []) or []
        doc_texts = []

        for f in files:
            if isinstance(f, dict):
                content = f.get("content") or f.get("text") or ""
                name = f.get("name") or f.get("filename") or "添付ドキュメント"
                if content:
                    doc_texts.append(f"### ドキュメント名: {name}\n{content[:self.valves.max_chars]}")

        if doc_texts:
            full_context = "\n\n".join(doc_texts)
            injection = f"\n\n<full_document_context>\n【添付ドキュメント全文】\n{full_context}\n</full_document_context>\n\n"
            
            # 最後のユーザーメッセージに注入
            for i in range(len(messages) - 1, -1, -1):
                if messages[i].get("role") == "user":
                    curr_content = messages[i].get("content", "")
                    if isinstance(curr_content, str):
                        messages[i]["content"] = injection + curr_content
                    elif isinstance(curr_content, list):
                        messages[i]["content"] = [{"type": "text", "text": injection}] + curr_content
                    break

        return body
