"""
title: Prompt Enhancer Filter
author: Open WebUI Community
author_url: https://openwebui.com
version: 1.0.0
description: 曖昧または短いユーザープロンプトを、具体的かつ論理的な指示・制約・出力形式を含む高品質なプロンプトに自動推敲・最適化します。
"""

from typing import Optional
from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=5, description="フィルター実行優先度")
        min_length_to_skip: int = Field(default=200, description="推敲をスキップする文字数閾値（すでに長文の場合はスキップ）")
        enabled: bool = Field(default=True, description="プロンプト推敲の有効化")

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        if not self.valves.enabled:
            return body

        messages = body.get("messages", [])
        if not messages:
            return body

        last_user_idx = -1
        for i in range(len(messages) - 1, -1, -1):
            if messages[i].get("role") == "user":
                last_user_idx = i
                break

        if last_user_idx == -1:
            return body

        user_content = messages[last_user_idx].get("content", "")
        if not isinstance(user_content, str):
            return body

        # スキップ判定（プレフィックスでスキップ、または既に十分に長い詳細プロンプト）
        if user_content.startswith("/raw ") or len(user_content) > self.valves.min_length_to_skip:
            if user_content.startswith("/raw "):
                messages[last_user_idx]["content"] = user_content[5:]
            return body

        # 推敲プロンプト枠組みの注入
        enhanced_instruction = (
            f"【ユーザーの入力】: {user_content}\n\n"
            "【回答時の指針】\n"
            "1. 目的と文脈を深く理解し、質問の本質に対して過不足なく回答してください。\n"
            "2. 必要に応じて具体的な例、コード、手順、または論理的根拠を提示してください。\n"
            "3. 構成は結論から始め、見出しや箇条書きを活用して視覚的にわかりやすく整理してください。\n"
            "4. 前提条件やエッジケース、潜在的な注意点があれば明記してください。"
        )

        messages[last_user_idx]["content"] = enhanced_instruction
        return body
