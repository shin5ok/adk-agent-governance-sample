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

"""policy-agent: 経費規程チェック担当（公開側）。

判定は LLM ではなく check_policy() に閉じている。
規程の評価は決定的であるべきで、金額の大小比較を確率的なモデルに投げる理由が無い。
"""

import os

from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.genai import types

MODEL = os.environ.get("ADK_MODEL", "gemini-3.7-flash")

_LIMITS = {"会食": 10000, "消耗品": 5000, "宿泊": 15000, "交通費": 30000}


def check_policy(amount: int, category: str) -> dict:
    """金額とカテゴリを経費規程と照合する。

    Args:
        amount: 金額（円）。外貨の領収書は円換算した後の金額を渡す
        category: 会食 / 消耗品 / 宿泊 / 交通費 のいずれか
    """
    limit = _LIMITS.get(category)
    if limit is None:
        return {"verdict": "REVIEW", "reason": f"未知のカテゴリ: {category}"}
    if amount > limit:
        return {
            "verdict": "VIOLATION",
            "reason": f"{category} の上限 {limit} 円を超過（{amount} 円）",
            "limit": limit,
        }
    return {"verdict": "OK", "limit": limit}


root_agent = Agent(
    name="policy_agent",
    model=Gemini(
        model=MODEL,
        retry_options=types.HttpRetryOptions(attempts=3),
    ),
    description="経費規程との照合を担当する",
    instruction=(
        "金額とカテゴリを受け取ったら check_policy で判定し、結果だけ返す。"
        "規程は円建てなので、円以外の金額を渡されたら判定せず、"
        "円換算した金額を渡すよう返す。"
    ),
    tools=[check_policy],
)

app = App(
    root_agent=root_agent,
    name="app",
)
