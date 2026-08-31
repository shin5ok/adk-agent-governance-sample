# ADK A2A + Agent Identity / Registry / Gateway / Model Armor sample
# ローカル: install → run → smoke → chat
# GCP:     gcp-apis → gcp-deploy → gcp-iam → gcp-gateway → gcp-model-armor

SHELL := /bin/bash
PY ?= python3
PIP ?= pip
RECEIPT_PORT ?= 8001
POLICY_PORT  ?= 8002
PIDDIR := .pids
LOGDIR := .logs

.PHONY: help install run stop smoke chat card agent-json api-server \
        gcp-apis gcp-deploy gcp-iam gcp-registry gcp-gateway gcp-model-armor \
        gh-create push clean

help: ## このヘルプ
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

install: ## 依存をインストール（google-adk[a2a,agent-identity]）
	$(PIP) install "google-adk[a2a]" "google-adk[agent-identity]"

run: stop ## receipt(8001) と policy(8002) をバックグラウンド起動
	@mkdir -p $(PIDDIR) $(LOGDIR)
	@setsid uvicorn agents.receipt_agent.agent:a2a_app --host localhost --port $(RECEIPT_PORT) \
	  > $(LOGDIR)/receipt.log 2>&1 & echo $$! > $(PIDDIR)/receipt.pid
	@setsid uvicorn agents.policy_agent.agent:a2a_app --host localhost --port $(POLICY_PORT) \
	  > $(LOGDIR)/policy.log 2>&1 & echo $$! > $(PIDDIR)/policy.pid
	@echo "waiting for agent cards..."
	@for i in $$(seq 1 30); do \
	  curl -sf localhost:$(RECEIPT_PORT)/.well-known/agent-card.json >/dev/null 2>&1 && \
	  curl -sf localhost:$(POLICY_PORT)/.well-known/agent-card.json  >/dev/null 2>&1 && break; \
	  sleep 1; done
	@echo "receipt-agent: http://localhost:$(RECEIPT_PORT)  policy-agent: http://localhost:$(POLICY_PORT)"

stop: ## バックグラウンドのエージェントを停止
	@for p in $(PIDDIR)/*.pid; do \
	  [ -f "$$p" ] && kill -TERM -- -$$(cat "$$p") 2>/dev/null; rm -f "$$p"; done || true
	@pkill -f "uvicorn agents\." 2>/dev/null || true
	@echo stopped

smoke: ## LLM 不要の疎通テスト（カード取得・URL整合・カード解決）
	$(PY) tests/smoke_test.py

card: ## 両エージェントのカードを表示
	@curl -s localhost:$(RECEIPT_PORT)/.well-known/agent-card.json | $(PY) -m json.tool
	@curl -s localhost:$(POLICY_PORT)/.well-known/agent-card.json | $(PY) -m json.tool

chat: ## adk web でオーケストレータと対話（要 GOOGLE_API_KEY）
	adk web .

agent-json: ## api_server 方式用の agent.json を生成（run 済みであること）
	$(PY) scripts/make_agent_json.py \
	  http://localhost:$(RECEIPT_PORT)/.well-known/agent-card.json \
	  http://localhost:$(RECEIPT_PORT)/a2a/receipt_agent \
	  agents/receipt_agent/agent.json
	$(PY) scripts/make_agent_json.py \
	  http://localhost:$(POLICY_PORT)/.well-known/agent-card.json \
	  http://localhost:$(POLICY_PORT)/a2a/policy_agent \
	  agents/policy_agent/agent.json

api-server: agent-json stop ## もう一つの公開方法: adk api_server --a2a で agents/ 配下を一括公開
	adk api_server --a2a --port $(RECEIPT_PORT) agents

# ---------- GCP ----------
gcp-apis: ## 必要な API を有効化
	./scripts/gcp_enable_apis.sh

gcp-deploy: ## Agent Runtime に Agent Identity 付きで3体デプロイ
	$(PIP) install "google-cloud-aiplatform[adk,agent_engines]"
	$(PY) scripts/gcp_deploy_agents.py

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
	rm -rf $(PIDDIR) $(LOGDIR) .adk __pycache__ */__pycache__ */*/__pycache__
