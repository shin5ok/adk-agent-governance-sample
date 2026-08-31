"""policy-agent: 経費規程チェック担当（公開側 / to_a2a 方式, port 8002）"""
import os

from google.adk.agents import Agent
from google.adk.a2a.utils.agent_to_a2a import to_a2a

PORT = int(os.environ.get("POLICY_AGENT_PORT", "8002"))

_LIMITS = {"会食": 10000, "消耗品": 5000, "宿泊": 15000, "交通費": 30000}


def check_policy(amount: int, category: str) -> dict:
    """金額とカテゴリを経費規程と照合する。

    Args:
        amount: 金額（円）
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
    model=os.environ.get("ADK_MODEL", "gemini-3.7-flash"),
    name="policy_agent",
    description="経費規程との照合を担当する",
    instruction="金額とカテゴリを受け取ったら check_policy で判定し、結果だけ返す。",
    tools=[check_policy],
)

a2a_app = to_a2a(root_agent, port=PORT)
