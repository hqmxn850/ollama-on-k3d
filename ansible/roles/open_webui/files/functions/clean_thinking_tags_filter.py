"""
title: Clean Thinking Tags Filter / Clean unclosed thinking tags
author: Haervwe / Open WebUI Community
author_url: https://openwebui.com
version: 1.0.0
description: DeepSeek-R1 や Qwen などの推論モデルが出力する <think> タグを整形し、ストリーミング中断等で途切れた未完了（unclosed）の思考タグを自動補正・整形します。
"""

import re
from typing import Optional
from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=10, description="フィルター実行優先度")
        close_unclosed_tags: bool = Field(default=True, description="未完結の <think> タグを自動で閉じる")
        hide_thinking: bool = Field(default=False, description="思考プロセスを非表示にして最終回答のみを残す")

    def __init__(self):
        self.valves = self.Valves()

    async def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        messages = body.get("messages", [])
        if not messages:
            return body

        last_msg = messages[-1]
        if last_msg.get("role") != "assistant":
            return body

        content = last_msg.get("content", "")
        if not isinstance(content, str):
            return body

        # 未完結の <think> タグの検出と補正
        if "<think>" in content and "</think>" not in content:
            if self.valves.close_unclosed_tags:
                content = content + "\n</think>\n"

        if self.valves.hide_thinking:
            # 思考部分を完全に削除して回答本文のみにする
            content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()

        last_msg["content"] = content
        return body
