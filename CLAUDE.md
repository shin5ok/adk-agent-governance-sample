# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Google ADK の A2A と GCP のエージェント統制（Agent Identity / Registry / Gateway /
Model Armor）を、経費精算チェックを題材に一通り動かすサンプル。
4体のうち fx-agent だけ Cloud Run 行き（別ランタイム）で、残りは Agent Runtime。
コード・コメント・ドキュメントは日本語で統一されている。
そのため、会話は日本語で実施する。

検証環境: agents-cli 1.4.2 / google-adk 2.x / a2a-sdk 1.x / Python 3.11 / uv

## 構成

**1プロジェクト = 1エージェント**の agents-cli プロジェクトが4つ並んでいる。

```
receipt-agent/          公開側。app/agent.py にツール、A2A は scaffold 由来
policy-agent/           公開側
fx-agent/               公開側。deployment_target: cloud_run（ここだけ別ランタイム）
expense-orchestrator/   呼ぶ側。AgentTool(RemoteA2aAgent) x3。--agent-gateway 付きで scaffold 済み
deploy/*.yaml           Gateway / IAP のマニフェスト（プレースホルダ）
scripts/gcp_*.sh        API 有効化 / IAM / Gateway / Model Armor / Registry
Makefile                4プロジェクトを束ねる薄いラッパ
```

各プロジェクト内では `agents-cli` / `uv` をそのまま使える。ルートの Makefile は
4つに同じ操作を流すためだけのもの。

役割の境界は receipt = 社内の事実だけ / fx = 社外由来の事実だけ /
policy = 判定だけ / orchestrator = 委譲と集約だけ。

## コマンド

```bash
make install          # 4プロジェクトに agents-cli install（= uv sync）
make run              # 公開側3体を uvicorn で起動（:18001 / :18002 / :18003）
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

ポートは `WEB_PORT=18000`（playground）/ `RECEIPT_PORT=18001` / `POLICY_PORT=18002` /
`FX_PORT=18003`。
既定値は他のアプリと衝突しにくい 18000 番台に寄せてある。
`make run` と `make chat` は起動前に `lsof` で確認し、埋まっていれば占有プロセスを
名指しして中断する（`$(call check_ports,...)`）。

## アーキテクチャ

```
expense-orchestrator （呼ぶ側 / AgentTool(RemoteA2aAgent) x3） ← playground で起動、サーブしない
   ├── receipt-agent  （公開側 :18001 / Agent Runtime 行き）   ← uvicorn でサーブ
   ├── policy-agent   （公開側 :18002 / Agent Runtime 行き）   ← uvicorn でサーブ
   └── fx-agent       （公開側 :18003 / Cloud Run 行き）       ← uvicorn でサーブ
```

**公開側**は `app/fast_api_app.py` を uvicorn でサーブする。A2A のルートは
`app/app_utils/a2a.py` の `attach_a2a_routes()` が `/a2a/{App.name}` に生やす。
**呼ぶ側**は `RemoteA2aAgent` でカード URL を解決する。オーケストレータは
サーブされない — この非対称性が構成を理解する鍵。

**ランタイムの違いはローカルには出ない。** `fx-agent` の `deployment_target` が
`cloud_run` なのは `agents-cli-manifest.yaml` の中だけの話で、ローカルでは3体とも
同じ uvicorn、A2A のカードのパスも同じ。差が出るのは `make gcp-deploy` 以降。

**委譲は `AgentTool` で行う（`sub_agents` ではない）。** `sub_agents` に置くと
`transfer_to_agent` で制御ごと渡り、渡した先から戻らないので1ターンで
receipt → fx → policy と辿れない。ADK は `mode='single_turn'` のサブエージェントを
ツールとして扱うが、`RemoteA2aAgent` は `mode` フィールドを持たないので
その道は使えず、`AgentTool(agent=...)` で包んで `tools=` に渡す必要がある。

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
- **リモートを `sub_agents` に置くと1体目で会話が止まる。** `AgentTool` で包む。
- **`--agent-identity` は Agent Runtime 専用。** Cloud Run へのデプロイでは無視される。
  fx-agent は SA で動き、Registry への登録も deploy 任せにはできない。
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
デプロイ先は各プロジェクトの `agents-cli-manifest.yaml` の `deployment_target` で
決まるので、fx-agent では同じ `agents-cli deploy` が `gcloud run deploy` に落ちる。

- **Agent Identity は組織必須。** `principal://agents.global.org-${ORG_ID}...` という
  形式に組織 ID が埋まるため、組織なしプロジェクトでは成立しない。長期鍵は存在しない。
- IAM は Agent Identity の `principal://` に対して付ける（SA ではない）。
  データアクセスは個体ごとに狭く絞る方針（`scripts/gcp_grant_iam.sh` 参照）。
- **Model Armor / IAP は INSPECT_ONLY / DRY_RUN から始める。** ログを確認してから遮断へ。
- Gateway は Registry 未登録の MCP を既定でブロックする。
- Model Armor テンプレートは Gateway と同じリージョンに作る必要がある。
- **Agent Registry への登録は `agents-cli publish` では出来ない**（publish の対象は
  Gemini Enterprise のみ）。`scripts/gcp_register_registry.sh` の gcloud を使う。
- **Agent Runtime の外にいる fx-agent には Agent Identity が付かない。** Registry へは
  手動登録し、呼ばれる側の保護は Cloud Run の IAM（`roles/run.invoker` を呼ぶ側の
  `principal://` に付ける）で行う。`FX_SERVICE_NAME=` を付けて `gcp-iam` を流す。

## 環境変数

ルートの `.env.example` は **GCP 統制スクリプト用**。`set -a; source .env` で流し込む。
エージェント自身の設定（プロジェクトID / 認証 / モデル）は各プロジェクトの `.env`。
`ADK_MODEL`（既定 `gemini-3.7-flash`）で4プロジェクト共通にモデルを差し替えられる。
