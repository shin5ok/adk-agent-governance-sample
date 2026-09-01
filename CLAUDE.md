# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Google ADK の A2A と GCP のエージェント統制（Agent Identity / Registry / Gateway /
Model Armor）を、経費精算チェックを題材に一通り動かすサンプル。
コード・コメント・ドキュメントは日本語で統一されている。
そのため、会話は日本語で実施する。

検証環境: agents-cli 1.4.2 / google-adk 2.x / a2a-sdk 1.x / Python 3.11 / uv

## 構成

**1プロジェクト = 1エージェント**の agents-cli プロジェクトが3つ並んでいる。

```
receipt-agent/          公開側。app/agent.py にツール、A2A は scaffold 由来
policy-agent/           公開側
expense-orchestrator/   呼ぶ側。RemoteA2aAgent x2。--agent-gateway 付きで scaffold 済み
deploy/*.yaml           Gateway / IAP のマニフェスト（プレースホルダ）
scripts/gcp_*.sh        API 有効化 / IAM / Gateway / Model Armor / Registry
Makefile                3プロジェクトを束ねる薄いラッパ
```

各プロジェクト内では `agents-cli` / `uv` をそのまま使える。ルートの Makefile は
3つに同じ操作を流すためだけのもの。

## コマンド

```bash
make install          # 3プロジェクトに agents-cli install（= uv sync）
make run              # 公開側2体を uvicorn で起動（:18001 / :18002）
make smoke            # A2A で1往復（agents-cli run --mode a2a）。LLM を呼ぶ
make card             # 生成されたエージェントカードを表示
make chat             # agents-cli playground でオーケストレータと対話（:18000）
make stop             # 停止
make lint / make test # agents-cli lint / uv run pytest
make help             # 全ターゲット
```

個別に叩くときは各プロジェクトへ `cd` する:

```bash
cd receipt-agent && agents-cli playground     # このエージェント単体の UI
cd receipt-agent && agents-cli run "R-1001 は?"  # ローカル1発実行
```

**`python3 -m venv` や `pip install` は使わない。** 依存は `uv sync`
（= `agents-cli install`）が各プロジェクトの `.venv` に入れる。Python を直接
叩くときは `uv run python ...` / `uv run --directory <proj> ...`。

ポートは `WEB_PORT=18000`（playground）/ `RECEIPT_PORT=18001` / `POLICY_PORT=18002`。
既定値は他のアプリと衝突しにくい 18000 番台に寄せてある。
`make run` と `make chat` は起動前に `lsof` で確認し、埋まっていれば占有プロセスを
名指しして中断する（`$(call check_ports,...)`）。

## アーキテクチャ

```
expense-orchestrator （呼ぶ側 / RemoteA2aAgent x2）   ← playground で起動、サーブしない
   ├── receipt-agent  （公開側 :18001）              ← uvicorn でサーブ
   └── policy-agent   （公開側 :18002）              ← uvicorn でサーブ
```

**公開側**は `app/fast_api_app.py` を uvicorn でサーブする。A2A のルートは
`app/app_utils/a2a.py` の `attach_a2a_routes()` が `/a2a/{App.name}` に生やす。
**呼ぶ側**は `RemoteA2aAgent` でカード URL を解決する。オーケストレータは
サーブされない — この非対称性が構成を理解する鍵。

### 生成物なので手で書かないファイル

`app/fast_api_app.py` / `app/app_utils/*` / `Dockerfile` / `agents-cli-manifest.yaml` /
`deployment/` は scaffold の生成物。**A2A のコードは絶対に手書きしない**（import パスも
`AgentCard` のスキーマもバージョン間で変わる）。触るのは `app/agent.py` と `.env` だけ。

### 踏み抜きやすい罠

- **`APP_URL` はカードに広告する URL を組むだけで bind しない。** 実際の待ち受けは
  uvicorn の `--port`。ズレると到達不能な URL がカードに載る（未設定だと
  `http://0.0.0.0:8000` が広告される）。Makefile の `serve_agent` マクロが
  `APP_URL` と `--port` を同時に渡して同期させている。
- **カードのパスは `/a2a/app/.well-known/agent-card.json`。** ルート直下は 404。
  `app` の部分は `app/agent.py` の `App(name=...)`（ディレクトリ名と一致させる規約）。
- **`agents-cli run --mode a2a --url` にはベース URL を渡す。** CLI が
  `/a2a/{app_name}` を自動で足すので、`/a2a/app` まで書くと二重になって 404。
- **`RemoteA2aAgent(use_legacy=)` の既定は `True`。** 新統合を使うには明示的に `False`。
- **`--agent-gateway` は scaffold 時のフラグ。** Dockerfile にゲートウェイのルート CA を
  信頼させる処理が入る。これ無しで `deploy --agent-gateway-egress` はできない。
  expense-orchestrator だけこのフラグ付きで作ってある。
- `make stop` の `pkill` パターンを `[a]pp\.fast_api_app` と書いているのは、
  pkill 自身のコマンドラインにマッチして make ごと死ぬのを避けるため。

## GCP 統制レイヤ

`make gcp-apis` → `gcp-deploy` → `gcp-iam` → `gcp-gateway` → `gcp-model-armor` の順。
`deploy/*.yaml` は `PROJECT_ID` / `REGION` をプレースホルダとして持ち、
`scripts/gcp_create_gateway.sh` が sed で置換して import する。

デプロイは `agents-cli deploy --agent-identity`（オーケストレータのみ
`--agent-gateway-egress $AGENT_GATEWAY` を追加）。自前の Python スクリプトは持たない。

- **Agent Identity は組織必須。** `principal://agents.global.org-${ORG_ID}...` という
  形式に組織 ID が埋まるため、組織なしプロジェクトでは成立しない。長期鍵は存在しない。
- IAM は Agent Identity の `principal://` に対して付ける（SA ではない）。
  データアクセスは個体ごとに狭く絞る方針（`scripts/gcp_grant_iam.sh` 参照）。
- **Model Armor / IAP は INSPECT_ONLY / DRY_RUN から始める。** ログを確認してから遮断へ。
- Gateway は Registry 未登録の MCP を既定でブロックする。
- Model Armor テンプレートは Gateway と同じリージョンに作る必要がある。
- **Agent Registry への登録は `agents-cli publish` では出来ない**（publish の対象は
  Gemini Enterprise のみ）。`scripts/gcp_register_registry.sh` の gcloud を使う。

## 環境変数

ルートの `.env.example` は **GCP 統制スクリプト用**。`set -a; source .env` で流し込む。
エージェント自身の設定（プロジェクトID / 認証 / モデル）は各プロジェクトの `.env`。
`ADK_MODEL`（既定 `gemini-3.7-flash`）で3プロジェクト共通にモデルを差し替えられる。
