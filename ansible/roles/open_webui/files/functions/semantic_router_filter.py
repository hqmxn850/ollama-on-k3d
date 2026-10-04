"""
title: Semantic Router Filter
author: Open WebUI Community
author_url: https://openwebui.com
version: 1.0.0
description: ユーザー入力の意図（コーディング、数学・推論、Web検索が必要な事実確認、一般的な会話）をセマンティックに判別し、最適なシステムプロンプトやモデル設定を自動適用します。
"""

import re
from typing import Optional
from pydantic import BaseModel, Field


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=1, description="フィルター実行優先度")
        enable_code_routing: bool = Field(default=True, description="コード・プログラミング質問の最適化")
        enable_math_routing: bool = Field(default=True, description="数学・論理推論質問の最適化")
        enable_search_hint: bool = Field(default=True, description="最新情報・事実確認の検索ヒント適用")

    def __init__(self):
        self.valves = self.Valves()

    async def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        messages = body.get("messages", [])
        if not messages:
            return body

        # 最新のユーザーメッセージを抽出
        user_msg = ""
        for m in reversed(messages):
            if m.get("role") == "user":
                user_msg = m.get("content", "")
                break

        if not isinstance(user_msg, str):
            return body

        router_prompt = ""
        user_lower = user_msg.lower()

        # 1. コーディング・技術的質問の検出
        code_patterns = [r"def ", r"class ", r"function", r"import ", r"コード", r"プログラム", r"エラー", r"バグ", r"実装", r"python", r"javascript", r"yaml", r"docker", r"k8s"]
        if self.valves.enable_code_routing and any(re.search(pat, user_lower) for pat in code_patterns):
            router_prompt = (
                "\n\n[System Router: コーディング専門モード]\n"
                "- 保守性・型安全性・エラーハンドリングを考慮した堅牢なコードを記述してください。\n"
                "- 必要に応じてコードブロックの前に簡潔な設計判断、後に使い方の解説を付記してください。"
            )

        # 2. 数学・論理・パズル・深い推論の検出
        math_patterns = [r"計算", r"証明", r"論理", r"なぜ", r"どうして", r"理由", r"解いて", r"math", r"logic", r"solve"]
        if self.valves.enable_math_routing and any(re.search(pat, user_lower) for pat in math_patterns):
            router_prompt = (
                "\n\n[System Router: 論理・ステップバイステップ推論モード]\n"
                "- 前提条件を整理し、論理の飛躍がないように段階的に思考（Step-by-step）を展開して回答してください。"
            )

        if router_prompt:
            # システムメッセージに追記、なければ新規追加
            has_sys = False
            for m in messages:
                if m.get("role") == "system":
                    m["content"] = str(m.get("content", "")) + router_prompt
                    has_sys = True
                    break
            if not has_sys:
                messages.insert(0, {"role": "system", "content": router_prompt.strip()})

        return body
