# ADK A2A + Agent Identity / Registry / Gateway / Model Armor sample
# ローカル: install → run → smoke → chat
# GCP:     gcp-apis → gcp-deploy → gcp-iam → gcp-gateway → gcp-model-armor
#
# 3つの agents-cli プロジェクト（1プロジェクト = 1エージェント）を束ねる薄いラッパ。
# 各プロジェクト内では agents-cli / uv をそのまま使える。

SHELL := /bin/bash

SERVED       := receipt-agent policy-agent
PROJECTS     := $(SERVED) expense-orchestrator

# 他のアプリと衝突しにくい 18000 番台を既定にしている。
RECEIPT_PORT ?= 18001
POLICY_PORT  ?= 18002
WEB_PORT     ?= 18000
PIDDIR := .pids
LOGDIR := .logs

# 実験機能の警告を落とす。RemoteA2aAgent が毎回出す。
export ADK_SUPPRESS_A2A_EXPERIMENTAL_FEATURE_WARNINGS = true

# 指定ポートが空いているか確認し、埋まっていれば占有プロセスを名指しして止まる。
define check_ports
@for port in $(1); do \
  if lsof -nP -iTCP:$$port -sTCP:LISTEN >/dev/null 2>&1; then \
    echo "ERROR: port $$port は既に他プロセスが使用中です:"; \
    lsof -nP -iTCP:$$port -sTCP:LISTEN | tail -n +2 | sed 's/^/  /'; \
    echo "  -> 解放するか、別ポートを指定: make <target> RECEIPT_PORT=.. POLICY_PORT=.. WEB_PORT=.."; \
    exit 1; \
  fi; \
done
endef

# 公開側を1つ起動する。$(1)=プロジェクト名 $(2)=ポート
# APP_URL は「カードに広告する URL」。uvicorn の --port とズレると到達不能な URL が載る。
define serve_agent
@APP_URL=http://localhost:$(2) nohup uv run --directory $(1) \
  uvicorn app.fast_api_app:app --host localhost --port $(2) \
  > $(LOGDIR)/$(1).log 2>&1 & echo $$! > $(PIDDIR)/$(1).pid
endef

.PHONY: help install run stop smoke card chat lint test \
        gcp-apis gcp-deploy gcp-iam gcp-registry gcp-gateway gcp-model-armor \
        gh-create push clean

help: ## このヘルプ
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

install: ## 3プロジェクトの依存をインストール（agents-cli install = uv sync）
	@for p in $(PROJECTS); do echo "--- $$p"; (cd $$p && agents-cli install) || exit 1; done

run: stop ## 公開側2体を uvicorn で起動（receipt/policy）
	@mkdir -p $(PIDDIR) $(LOGDIR)
	$(call check_ports,$(RECEIPT_PORT) $(POLICY_PORT))
	$(call serve_agent,receipt-agent,$(RECEIPT_PORT))
	$(call serve_agent,policy-agent,$(POLICY_PORT))
	@echo "waiting for agent cards..."
	@for i in $$(seq 1 60); do \
	  if curl -sf localhost:$(RECEIPT_PORT)/a2a/app/.well-known/agent-card.json >/dev/null 2>&1 && \
	     curl -sf localhost:$(POLICY_PORT)/a2a/app/.well-known/agent-card.json  >/dev/null 2>&1; then \
	    echo "receipt-agent: http://localhost:$(RECEIPT_PORT)  policy-agent: http://localhost:$(POLICY_PORT)"; \
	    exit 0; \
	  fi; \
	  sleep 1; \
	done; \
	echo "ERROR: 60秒以内にエージェントカードが取得できませんでした。ログ:"; \
	tail -n 20 $(LOGDIR)/*.log; \
	exit 1

stop: ## 公開側を停止
	@for p in $(PIDDIR)/*.pid; do \
	  [ -f "$$p" ] || continue; \
	  kill -TERM "$$(cat "$$p")" 2>/dev/null || true; \
	  rm -f "$$p"; \
	done
	@# パターンを [a]pp と書くのは、pkill 自身のコマンドラインに
	@# マッチして make ごと殺してしまうのを避けるため。
	@pkill -f "[a]pp\.fast_api_app" 2>/dev/null || true
	@echo stopped

smoke: ## 公開側2体に A2A で1往復させる（agents-cli run --mode a2a）
	@cd receipt-agent && agents-cli run "R-1003 の領収書の内容を教えて" \
	  --url http://localhost:$(RECEIPT_PORT) --mode a2a
	@cd policy-agent && agents-cli run "宿泊で 45000 円は規程に適合しますか" \
	  --url http://localhost:$(POLICY_PORT) --mode a2a

card: ## 両エージェントのカードを表示
	@curl -s localhost:$(RECEIPT_PORT)/a2a/app/.well-known/agent-card.json | python3 -m json.tool
	@curl -s localhost:$(POLICY_PORT)/a2a/app/.well-known/agent-card.json | python3 -m json.tool

chat: ## オーケストレータと対話（agents-cli playground = adk web）
	$(call check_ports,$(WEB_PORT))
	@cd expense-orchestrator && agents-cli playground --port $(WEB_PORT)

lint: ## 3プロジェクトの静的チェック
	@for p in $(PROJECTS); do echo "--- $$p"; (cd $$p && agents-cli lint) || exit 1; done

test: ## 3プロジェクトの unit / integration テスト
	@# integration テストは実際にモデルを呼ぶ。pytest は .env を読まないので
	@# ここで流し込む（uvicorn 経由なら fast_api_app.py の load_dotenv が効く）。
	@for p in $(PROJECTS); do echo "--- $$p"; \
	  ( cd $$p; set -a; [ -f .env ] && . ./.env; set +a; \
	    uv run pytest tests/unit tests/integration ) || exit 1; done

# ---------- GCP ----------
gcp-apis: ## 必要な API を有効化
	./scripts/gcp_enable_apis.sh

gcp-deploy: ## Agent Runtime に Agent Identity 付きで3体デプロイ
	@for p in $(SERVED); do echo "--- $$p"; (cd $$p && agents-cli deploy --agent-identity) || exit 1; done
	@cd expense-orchestrator && agents-cli deploy --agent-identity \
	  $${AGENT_GATEWAY:+--agent-gateway-egress $$AGENT_GATEWAY}

gcp-iam: ## Agent Identity（principal://）へ IAM 付与（AGENT_ENGINE_ID= を指定）
	./scripts/gcp_grant_iam.sh

gcp-registry: ## Runtime 外エージェントを Agent Registry に手動登録（AGENT_BASE_URL= を指定）
	./scripts/gcp_register_registry.sh

gcp-gateway: ## Agent Gateway（egress）+ IAP 認可（DRY_RUN）を作成
	./scripts/gcp_create_gateway.sh

gcp-model-armor: ## Model Armor テンプレート作成 + SA へロール付与
	./scripts/gcp_model_armor.sh

# ---------- GitHub ----------
gh-create: ## gh CLI で GitHub リポジトリを作成して push（REPO=owner/name）
	@: "$${REPO:?REPO=owner/name を指定してください}"
	gh repo create "$$REPO" --public --source=. --remote=origin --push

push: ## origin へ push（リモート設定済みの場合）
	git push -u origin main

clean: stop ## 生成物を削除
	rm -rf $(PIDDIR) $(LOGDIR)
