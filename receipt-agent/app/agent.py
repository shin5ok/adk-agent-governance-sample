# ruff: noqa
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""receipt-agent: 領収書の読み取り担当（公開側）。

A2A のエンドポイントは app/fast_api_app.py が /a2a/app に生やす。
このファイルはエージェントの中身だけを持つ。
"""

import os

from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.genai import types

MODEL = os.environ.get("ADK_MODEL", "gemini-3.7-flash")

# --- 本来は OCR + BigQuery。ローカルで完結するようモックデータで代替 ---
# R-1004 / R-1005 は海外出張の領収書。金額が外貨建てなので、
# 規程判定の前に fx-agent で円換算する必要がある。
_EXPENSE_DB = {
    "R-1001": {
        "amount": 12800,
        "currency": "JPY",
        "date": "2026-08-20",
        "store": "居酒屋やまだ",
        "category": "会食",
    },
    "R-1002": {
        "amount": 980,
        "currency": "JPY",
        "date": "2026-08-21",
        "store": "セブンイレブン",
        "category": "消耗品",
    },
    "R-1003": {
        "amount": 45000,
        "currency": "JPY",
        "date": "2026-08-22",
        "store": "ホテルグランデ",
        "category": "宿泊",
    },
    "R-1004": {
        "amount": 320.00,
        "currency": "USD",
        "date": "2026-08-22",
        "store": "Hotel Bayview",
        "category": "宿泊",
    },
    "R-1005": {
        "amount": 38.60,
        "currency": "EUR",
        "date": "2026-08-23",
        "store": "Cafe Roma",
        "category": "会食",
    },
}


def extract_receipt(receipt_id: str) -> dict:
    """領収書IDから金額・通貨・日付・店舗・カテゴリを取り出す。

    Args:
        receipt_id: R-XXXX 形式の領収書ID
    """
    rec = _EXPENSE_DB.get(receipt_id)
    if rec is None:
        return {"error": f"領収書 {receipt_id} が見つかりません"}
    return {"receipt_id": receipt_id, **rec}


def list_receipts() -> list[str]:
    """登録済みの領収書IDを一覧する。"""
    return sorted(_EXPENSE_DB)


root_agent = Agent(
    name="receipt_agent",
    model=Gemini(
        model=MODEL,
        retry_options=types.HttpRetryOptions(attempts=3),
    ),
    description="領収書の読み取りと経費データとの突き合わせを担当する",
    instruction=(
        "領収書に関する依頼を受けたら extract_receipt / list_receipts を使って"
        "事実だけを返す。判定はしない。金額を返すときは通貨コードを必ず添える。"
    ),
    tools=[extract_receipt, list_receipts],
)

app = App(
    root_agent=root_agent,
    name="app",
)
