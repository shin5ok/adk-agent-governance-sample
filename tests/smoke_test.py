#!/usr/bin/env python3
"""LLM を呼ばずに通る範囲の疎通テスト。

1. 両エージェントのカードが 200 で返り、必須フィールドを持つ
2. カードの supportedInterfaces[].url がサーブ中のポートと一致（ズレ検出）
3. RemoteA2aAgent がカードを解決できる
"""
import asyncio
import json
import os
import sys
import urllib.request

RECEIPT_URL = os.environ.get("RECEIPT_AGENT_URL", "http://localhost:8001")
POLICY_URL = os.environ.get("POLICY_AGENT_URL", "http://localhost:8002")

FAIL = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global FAIL
    mark = "ok" if ok else "NG"
    print(f"  [{mark}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAIL += 1


def fetch_card(base: str) -> dict:
    with urllib.request.urlopen(f"{base}/.well-known/agent-card.json", timeout=10) as r:
        return json.load(r)


def test_cards() -> None:
    for label, base in (("receipt", RECEIPT_URL), ("policy", POLICY_URL)):
        card = fetch_card(base)
        check(f"{label}: card fetched", True)
        check(f"{label}: has skills", bool(card.get("skills")))
        urls = [i.get("url") for i in card.get("supportedInterfaces", [])]
        check(
            f"{label}: card url matches served port",
            base in urls,
            f"card={urls} served={base}",
        )


async def test_resolution() -> None:
    from google.adk.agents.remote_a2a_agent import (
        AGENT_CARD_WELL_KNOWN_PATH,
        RemoteA2aAgent,
    )

    agent = RemoteA2aAgent(
        name="receipt_agent",
        description="smoke",
        agent_card=f"{RECEIPT_URL}{AGENT_CARD_WELL_KNOWN_PATH}",
        use_legacy=False,
    )
    await agent._ensure_resolved()
    check("RemoteA2aAgent resolved card", agent._agent_card is not None)


def main() -> None:
    print("smoke test:")
    test_cards()
    asyncio.run(test_resolution())
    print(f"\n{'PASSED' if FAIL == 0 else 'FAILED'} ({FAIL} failure(s))")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
