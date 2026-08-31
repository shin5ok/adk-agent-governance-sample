"""receipt-agent: 領収書の読み取り担当（公開側 / to_a2a 方式, port 18001）"""
import os

from google.adk.agents import Agent
from google.adk.a2a.utils.agent_to_a2a import to_a2a

PORT = int(os.environ.get("RECEIPT_AGENT_PORT", "18001"))

# --- 本来は OCR + BigQuery。ローカルで完結するようモックデータで代替 ---
_EXPENSE_DB = {
    "R-1001": {"amount": 12800, "date": "2026-08-20", "store": "居酒屋やまだ", "category": "会食"},
    "R-1002": {"amount": 980,   "date": "2026-08-21", "store": "セブンイレブン", "category": "消耗品"},
    "R-1003": {"amount": 45000, "date": "2026-08-22", "store": "ホテルグランデ", "category": "宿泊"},
}


def extract_receipt(receipt_id: str) -> dict:
    """領収書IDから金額・日付・店舗・カテゴリを取り出す。

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
    model=os.environ.get("ADK_MODEL", "gemini-3.7-flash"),
    name="receipt_agent",
    description="領収書の読み取りと経費データとの突き合わせを担当する",
    instruction=(
        "領収書に関する依頼を受けたら extract_receipt / list_receipts を使って"
        "事実だけを返す。判定はしない。"
    ),
    tools=[extract_receipt, list_receipts],
)

# この1行で A2A 対応の ASGI アプリになる。
# 注意: port はカードに載せる URL を組むだけ。uvicorn の --port と一致させること。
a2a_app = to_a2a(root_agent, port=PORT)
