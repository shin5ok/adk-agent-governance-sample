# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Google ADK の A2A と GCP のエージェント統制（Agent Identity / Registry / Gateway /
Model Armor）を、経費精算チェックを題材に一通り動かすサンプル。
コード・コメント・ドキュメントは日本語で統一されている。
そのため、会話は日本語で実施する。

検証環境: google-adk 2.8.0 / a2a-sdk 1.1.2 / Python 3.11

## コマンド

```bash
make venv             # .venv を作る（初回のみ）。activate は不要
make install          # google-adk[a2a,agent-identity]>=2.8
make run              # receipt(:18001) / policy(:18002) を uvicorn で起動
make smoke            # LLM 不要の疎通テスト。ここが緑にならない限り先へ進まない
make card             # 生成されたエージェントカードを表示
make stop             # 停止（.pids/*.pid + pkill の二段構え）
make chat             # adk web でオーケストレータと対話（:18000 / 要 GOOGLE_API_KEY）
make help             # 全ターゲット
```

`.venv` があれば `PY` / `PIP` / `ADK` は自動で `.venv/bin/*` を指すので activate は不要。
別のインタプリタを使うときだけ `make run PY=/path/to/python` と渡す。uvicorn は
`$(PY) -m uvicorn` として起動するため、インタプリタが混ざることはない。
`make venv` だけは `BOOTSTRAP_PY`（既定 `python3`）を使う — 壊れた `.venv` を
自分自身の python で作り直そうとして詰むのを避けるため。

ポートは `WEB_PORT=18000`（adk web）/ `RECEIPT_PORT=18001` / `POLICY_PORT=18002`。
既定値は他のアプリと衝突しにくい 18000 番台に寄せてある。
`make run` と `make chat` は起動前に `lsof` で確認し、埋まっていれば占有プロセスを
名指しして中断する（`$(call check_ports,...)`）。回避は
`make run RECEIPT_PORT=28001 POLICY_PORT=28002`（`make smoke` にも同じ変数を渡すこと）。

### テスト

テストフレームワークは無い。`tests/smoke_test.py` は単体で動く1本のスクリプトで、
`make smoke` がポートを環境変数に流し込んで実行する。個別に走らせるなら
`RECEIPT_AGENT_URL` / `POLICY_AGENT_URL` で対象を差し替える:

```bash
RECEIPT_AGENT_URL=http://localhost:28001 .venv/bin/python tests/smoke_test.py
```

失敗は例外ではなく `[NG]` 行 + 終了コード 1 で表現する。
`fetch_card()` は取得失敗時も例外を投げず None を返す設計（片方が落ちても
もう片方の検査を続けるため）。ここを例外送出に戻さないこと。

## アーキテクチャ

```
expense-orchestrator （呼ぶ側 / RemoteA2aAgent x2）   ← adk web で起動、サーブしない
   ├── receipt-agent  （公開側 :18001）              ← uvicorn でサーブ
   └── policy-agent   （公開側 :18002）              ← uvicorn でサーブ
```

**公開側**（`agents/*/agent.py`）は `to_a2a(root_agent, port=PORT)` 一行で ASGI アプリ
`a2a_app` になる。**呼ぶ側**（`orchestrator/agent.py`）は `RemoteA2aAgent` でカード URL を
解決する。オーケストレータはサーブされない — この非対称性が構成を理解する鍵。

`scripts/gcp_deploy_agents.py` は同じ `root_agent` を3つとも import するので、
ローカルで import が壊れるとデプロイも壊れる。

### 踏み抜きやすい罠

- **`to_a2a(port=)` は bind しない。** カードに広告する URL を組み立てるだけで、
  実際の待ち受けは uvicorn の `--port`。ズレると到達不能な URL がカードに載る。
  Makefile が `RECEIPT_AGENT_PORT` を `RECEIPT_PORT` から渡して同期させており、
  smoke test の "card url matches served port" はこのズレ専用の検査。
- **カードのパスは `/.well-known/agent-card.json`**（a2a-sdk 1.x）。旧 `agent.json` は 404。
- **`RemoteA2aAgent(use_legacy=)` の既定は `True`。** 新統合を使うには明示的に `False`。
- **`agents/*/agent.json` は生成物**（.gitignore 済み）。`make agent-json` が
  稼働中のサーバから吸い出して作る。手書きしない。
- macOS には `setsid` が無いため `make run` は `nohup` を使う。`make stop` は
  プロセスグループ（`-PID`）ではなく PID を kill する。

### 2つの公開方式

既定は `to_a2a` 方式（エージェントごとに uvicorn、カード URL は `http://host:port`）。
もう一つが `make api-server`（`adk api_server --a2a` で `agents/` 配下を一括公開、
カード URL は `/a2a/<name>` 形式）。後者は `make agent-json` で生成した
`agent.json` を必要とするため `run` → `agent-json` → `api-server` の順に依存する。

### オーケストレータの2モード

`USE_AGENT_REGISTRY=1` で解決方法が切り替わる（`orchestrator/agent.py`）:
既定は URL 直指定（ローカル完結）、Registry モードは `agents/<name>` という
名前だけで解決する（要 GCP、URL のハードコードが消える）。

## GCP 統制レイヤ

`make gcp-apis` → `gcp-deploy` → `gcp-iam` → `gcp-gateway` → `gcp-model-armor` の順。
`deploy/*.yaml` は `PROJECT_ID` / `REGION` をプレースホルダとして持ち、
`scripts/gcp_create_gateway.sh` が sed で置換して import する。

- **Agent Identity は組織必須。** `principal://agents.global.org-${ORG_ID}...` という
  形式に組織 ID が埋まるため、組織なしプロジェクトでは成立しない。長期鍵は存在しない。
- IAM は Agent Identity の `principal://` に対して付ける（SA ではない）。
  データアクセスは個体ごとに狭く絞る方針（`scripts/gcp_grant_iam.sh` 参照）。
- **Model Armor / IAP は INSPECT_ONLY / DRY_RUN から始める。** ログを確認してから遮断へ。
- Gateway は Registry 未登録の MCP を既定でブロックする。
- Model Armor テンプレートは Gateway と同じリージョンに作る必要がある。

## 環境変数

`.env.example` を `.env` にコピーして使う。GCP 系は `set -a; source .env` で流し込む。
`ADK_MODEL`（既定 `gemini-3.7-flash`）でモデルを差し替え可能。
