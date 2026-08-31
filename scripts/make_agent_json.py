#!/usr/bin/env python3
"""to_a2a が自動生成したカードを吸い出し、api_server 方式用の agent.json を作る。

使い方: python scripts/make_agent_json.py <card_url> <served_url> <out_path>
例:     python scripts/make_agent_json.py \
            http://localhost:18001/.well-known/agent-card.json \
            http://localhost:18001/a2a/receipt_agent \
            agents/receipt_agent/agent.json
"""
import json
import sys
import urllib.request


def main() -> None:
    card_url, served_url, out_path = sys.argv[1:4]
    with urllib.request.urlopen(card_url) as r:
        card = json.load(r)
    card["supportedInterfaces"] = [{
        "url": served_url,
        "protocolBinding": "JSONRPC",
        "protocolVersion": "1.0",
    }]
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(card, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {out_path} (url={served_url})")


if __name__ == "__main__":
    main()
