"""
title: Web Search
author: Open WebUI
version: 1.0.0
description: DuckDuckGo を使用してインターネット上の最新ニュース、天気、情報を検索します。
"""

from ddgs import DDGS

class Tools:
    def __init__(self):
        pass

    def search_web(self, query: str, count: int = 5, region: str = "jp-jp") -> str:
        """
        インターネットを検索して最新の情報（ニュース、天気、事実など）を取得します。
        :param query: 検索キーワードや質問
        :param count: 取得する検索結果の件数 (デフォルト: 5)
        :param region: 検索対象の地域コード (デフォルト: "jp-jp" 日本地域優先)
        :return: 検索結果（タイトル、URL、要約スニペット）
        """
        try:
            with DDGS() as ddgs:
                try:
                    results = list(ddgs.text(query, region=region, max_results=count))
                except Exception:
                    results = []
                if not results:
                    results = list(ddgs.text(query, max_results=count))
                if not results:
                    return f"「{query}」に関する検索結果は見つかりませんでした。"
                
                output = []
                for i, r in enumerate(results, 1):
                    title = r.get("title", "")
                    url = r.get("href", "")
                    body = r.get("body", "")
                    output.append(f"[{i}] {title}\nURL: {url}\n要約: {body}\n")
                return "\n".join(output)
        except Exception as e:
            return f"検索エラー: {str(e)}"
