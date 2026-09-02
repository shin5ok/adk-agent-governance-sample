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

"""fx-agent: 外貨建て金額の円換算担当（公開側 / 別ランタイム）。

このプロジェクトだけ `deployment_target: cloud_run` で scaffold してある。
他の3体が載る Agent Runtime とは別のランタイムで動く、という想定のエージェント。
A2A から見た振る舞いは他の公開側と変わらない（カードのパスも /a2a/app のまま）。
違うのは GCP 側で、Agent Identity が発行されないので Agent Registry へは
手動登録し、呼ばれる側の保護は Cloud Run の IAM で行う。

レートは社外の為替サービス由来という設定。判定はしない。
"""

import os

from google.adk.agents import Agent
from google.adk.apps import App
from google.adk.models import Gemini
from google.genai import types

MODEL = os.environ.get("ADK_MODEL", "gemini-3.7-flash")

# --- 本来は社外の為替 API。Agent Gateway の egress 制御対象になる想定で、
#     ローカルではスナップショットで代替する ---
_AS_OF = "2026-08-22"
_RATES = {
    "USD": 152.30,
    "EUR": 165.80,
    "GBP": 193.40,
    "KRW": 0.111,
}


def convert_to_jpy(amount: float, currency: str) -> dict:
    """外貨建ての金額を円に換算する。

    Args:
        amount: 外貨建ての金額
        currency: USD / EUR / GBP / KRW などの通貨コード
    """
    code = currency.upper()
    if code == "JPY":
        return {"amount_jpy": round(amount), "currency": "JPY", "rate": 1.0}
    rate = _RATES.get(code)
    if rate is None:
        return {"error": f"レートを持っていない通貨: {currency}"}
    return {
        "amount_jpy": round(amount * rate),
        "currency": code,
        "rate": rate,
        "as_of": _AS_OF,
        "source": "社外の為替サービス",
    }


def list_rates() -> dict:
    """換算できる通貨と適用レートを一覧する。"""
    return {"as_of": _AS_OF, "rates": _RATES}


root_agent = Agent(
    name="fx_agent",
    model=Gemini(
        model=MODEL,
        retry_options=types.HttpRetryOptions(attempts=3),
    ),
    description="外貨建て金額の円換算を担当する",
    instruction=(
        "換算の依頼を受けたら convert_to_jpy / list_rates を使って"
        "換算後の金額とレートだけを返す。規程に適合するかどうかの判定はしない。"
    ),
    tools=[convert_to_jpy, list_rates],
)

app = App(
    root_agent=root_agent,
    name="app",
)
