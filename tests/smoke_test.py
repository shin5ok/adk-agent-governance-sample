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
import urllib.error
import urllib.request

RECEIPT_URL = os.environ.get("RECEIPT_AGENT_URL", "http://localhost:18001")
POLICY_URL = os.environ.get("POLICY_AGENT_URL", "http://localhost:18002")

FAIL = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global FAIL
    mark = "ok" if ok else "NG"
    print(f"  [{mark}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAIL += 1


def fetch_card(base: str, label: str) -> dict | None:
    """カードを取得する。失敗したら check() で理由を報告し None を返す。

    ここで例外を投げてはいけない。このテストの仕事は「エージェントが正しく
    動いていない」ことを *検出して報告する* ことであって、道連れに落ちることではない。
    （素の traceback を出すと、もう一方のエージェントの検査まで実行されなくなる）

    分岐は「根本原因が決定的に異なる」2つだけに絞ってある:

      HTTPError  何かが応答している。エージェントではない別プロセスがポートを
                 占有しているか、ADK のバージョン差でカードのパスが違う。
                 応答ボディの先頭が「ADK かどうか」を一発で教えるので必ず出す。
      その他      そもそも到達できない（未起動 / timeout / JSON が壊れている等）。

    この2つを「取得失敗」に丸めると、ポート占有事故が二度と見抜けなくなる。
    逆にこれ以上細かく割っても、打つ手は変わらない。
    """
    url = f"{base}/.well-known/agent-card.json"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read(200).decode("utf-8", "replace").replace("\n", " ").strip()
        check(f"{label}: card fetched", False,
              f"HTTP {e.code} @ {url} — 応答: {body!r}")
    except Exception as e:
        check(f"{label}: card fetched", False,
              f"{type(e).__name__}: {e} @ {url}")
    return None


def test_cards() -> None:
    for label, base in (("receipt", RECEIPT_URL), ("policy", POLICY_URL)):
        card = fetch_card(base, label)
        if card is None:
            continue
        check(f"{label}: card fetched", True)
        check(f"{label}: has skills", bool(card.get("skills")))
        urls = [i.get("url") for i in card.get("supportedInterfaces", [])]
        check(
            f"{label}: card url matches served port",
            base in urls,
            f"card={urls} served={base}",
        )


async def test_resolution() -> None:
    try:
        from google.adk.agents.remote_a2a_agent import (
            AGENT_CARD_WELL_KNOWN_PATH,
            RemoteA2aAgent,
        )
    except ImportError as e:
        check("RemoteA2aAgent import", False, f"{e} — `make install` で google-adk を更新")
        return

    agent = RemoteA2aAgent(
        name="receipt_agent",
        description="smoke",
        agent_card=f"{RECEIPT_URL}{AGENT_CARD_WELL_KNOWN_PATH}",
        use_legacy=False,
    )
    try:
        await agent._ensure_resolved()
    except Exception as e:
        check("RemoteA2aAgent resolved card", False, f"{type(e).__name__}: {e}")
        return
    check("RemoteA2aAgent resolved card", agent._agent_card is not None)


def main() -> None:
    print("smoke test:")
    test_cards()
    asyncio.run(test_resolution())
    print(f"\n{'PASSED' if FAIL == 0 else 'FAILED'} ({FAIL} failure(s))")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
