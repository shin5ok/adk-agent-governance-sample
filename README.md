# ADK Agent Governance Sample

経費精算チェックを題材に、Google ADK の A2A と GCP のエージェント統制
（**Agent Identity / SPIFFE ID・Agent Registry・Agent Gateway・Model Armor**）を
一通り動かすサンプルです。ローカル部分は API キーなしでも疎通確認まで動きます。

```
expense-orchestrator (呼ぶ側 / RemoteA2aAgent x2)
   ├── receipt-agent  (公開側 :8001 / 領収書の読み取り)
   └── policy-agent   (公開側 :8002 / 経費規程チェック)
```

検証環境: google-adk 2.8.0 / a2a-sdk 1.1.2 / Python 3.11

## ローカルで動かす

```bash
make install   # google-adk[a2a,agent-identity]
make run       # 2エージェントをバックグラウンド起動
make smoke     # カード取得・URL整合・RemoteA2aAgent 解決（LLM不要）
make card      # エージェントカードを眺める

cp .env.example .env   # GOOGLE_API_KEY を入れて
make chat      # adk web でオーケストレータと対話（:8000）
make stop
```

対話例: 「R-1001 と R-1003 の経費をチェックして」
→ receipt_agent が内容を取り、policy_agent が規程判定し、
   R-1003（宿泊 45,000 円 > 上限 15,000 円）だけ違反として報告されます。

### もう一つの公開方法（adk api_server --a2a）

```bash
make run agent-json   # 自動生成カードを吸い出して agent.json を作る
make api-server       # agents/ 配下を一括公開（カードURLは /a2a/<name>/... 形式）
```

## GCP に載せる（要: 組織付きプロジェクト）

```bash
cp .env.example .env  # GCP 変数を埋めて `set -a; source .env`
make gcp-apis         # API 有効化
make gcp-deploy       # Agent Runtime へ identity_type=AGENT_IDENTITY で3体デプロイ
                      # → 出力される SPIFFE ID を控える
AGENT_ENGINE_ID=xxxx make gcp-iam        # principal:// へ IAM（expressUser / egressor 等）
AGENT_BASE_URL=https://... make gcp-registry  # Runtime 外エージェントの手動登録
make gcp-gateway      # Agent Gateway (egress) + IAP 認可（まず DRY_RUN）
make gcp-model-armor  # Model Armor テンプレート + SA ロール
```

Registry 経由でサブエージェントを解決するには `USE_AGENT_REGISTRY=1` を
セットしてオーケストレータを起動します（URL のハードコードが消えます）。

## 押さえどころ

- `to_a2a(port=)` は bind しない。uvicorn の `--port` とズレると
  到達不能な URL がカードに広告される（smoke テストが検出します）
- カードのパスは `/.well-known/agent-card.json`（a2a-sdk 1.x）。旧 `agent.json` は 404
- `RemoteA2aAgent` の `use_legacy` は既定 `True`。新統合は明示的に `False`
- Agent Identity は組織必須（trust domain に org ID が入る）。長期鍵は存在しない
- Gateway は Registry 未登録の MCP を既定でブロック。Model Armor / IAP は
  INSPECT_ONLY / DRY_RUN から始める

## GitHub へ push

```bash
REPO=yourname/adk-agent-governance-sample make gh-create   # gh CLI で作成+push
# または手動:
git remote add origin git@github.com:yourname/adk-agent-governance-sample.git
make push
```
