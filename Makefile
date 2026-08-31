# ADK A2A + Agent Identity / Registry / Gateway / Model Armor sample
# ローカル: install → run → smoke → chat
# GCP:     gcp-apis → gcp-deploy → gcp-iam → gcp-gateway → gcp-model-armor

SHELL := /bin/bash
VENV   := .venv

# .venv があればそれを使う。activate 忘れでシステムの python3 を掴む事故を防ぐ。
# いずれも PY=... のように明示指定すれば従来どおり上書きできる。
PY  ?= $(if $(wildcard $(VENV)/bin/python),$(VENV)/bin/python,python3)
PIP ?= $(if $(wildcard $(VENV)/bin/pip),$(VENV)/bin/pip,pip)
ADK ?= $(if $(wildcard $(VENV)/bin/adk),$(VENV)/bin/adk,adk)
# venv 自体を作る用。壊れた .venv を作り直せるよう $(PY) とは分ける。
BOOTSTRAP_PY ?= python3

RECEIPT_PORT ?= 18001
POLICY_PORT  ?= 18002
PIDDIR := .pids
LOGDIR := .logs

.PHONY: help venv install run stop smoke chat card agent-json api-server \
        gcp-apis gcp-deploy gcp-iam gcp-registry gcp-gateway gcp-model-armor \
        gh-create push clean

help: ## このヘルプ
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

venv: ## .venv を作成（初回のみ / 有効化してから make install）
	$(BOOTSTRAP_PY) -m venv $(VENV)
	@echo "  有効化: source $(VENV)/bin/activate"
	@echo "  その後: make install"

install: ## 依存をインストール（google-adk[a2a,agent-identity]）
	$(PIP) install --upgrade "google-adk[a2a,agent-identity]>=2.8"
	@$(PY) -c "import google.adk; print('installed google-adk', google.adk.__version__)"

run: stop ## receipt(18001) と policy(18002) をバックグラウンド起動
	@mkdir -p $(PIDDIR) $(LOGDIR)
	@$(PY) -c "import google.adk.a2a" 2>/dev/null || { \
	  echo "ERROR: $(PY) に google-adk[a2a] が入っていません"; \
	  echo "  -> make install（.venv が無ければ make venv から）"; \
	  exit 1; }
	@for port in $(RECEIPT_PORT) $(POLICY_PORT); do \
	  if lsof -nP -iTCP:$$port -sTCP:LISTEN >/dev/null 2>&1; then \
	    echo "ERROR: port $$port は既に他プロセスが使用中です:"; \
	    lsof -nP -iTCP:$$port -sTCP:LISTEN | tail -n +2 | sed 's/^/  /'; \
	    echo "  -> 解放するか、別ポートで: make run RECEIPT_PORT=28001 POLICY_PORT=28002"; \
	    exit 1; \
	  fi; \
	done
	@RECEIPT_AGENT_PORT=$(RECEIPT_PORT) nohup $(PY) -m uvicorn agents.receipt_agent.agent:a2a_app --host localhost --port $(RECEIPT_PORT) \
	  > $(LOGDIR)/receipt.log 2>&1 & echo $$! > $(PIDDIR)/receipt.pid
	@POLICY_AGENT_PORT=$(POLICY_PORT) nohup $(PY) -m uvicorn agents.policy_agent.agent:a2a_app --host localhost --port $(POLICY_PORT) \
	  > $(LOGDIR)/policy.log 2>&1 & echo $$! > $(PIDDIR)/policy.pid
	@echo "waiting for agent cards..."
	@for i in $$(seq 1 30); do \
	  if curl -sf localhost:$(RECEIPT_PORT)/.well-known/agent-card.json >/dev/null 2>&1 && \
	     curl -sf localhost:$(POLICY_PORT)/.well-known/agent-card.json  >/dev/null 2>&1; then \
	    echo "receipt-agent: http://localhost:$(RECEIPT_PORT)  policy-agent: http://localhost:$(POLICY_PORT)"; \
	    exit 0; \
	  fi; \
	  sleep 1; \
	done; \
	echo "ERROR: 30秒以内にエージェントカードが取得できませんでした。ログ:"; \
	tail -n 20 $(LOGDIR)/receipt.log $(LOGDIR)/policy.log; \
	exit 1

stop: ## バックグラウンドのエージェントを停止
	@for p in $(PIDDIR)/*.pid; do \
	  [ -f "$$p" ] || continue; \
	  kill -TERM "$$(cat "$$p")" 2>/dev/null || true; \
	  rm -f "$$p"; \
	done
	@pkill -f "uvicorn agents\." 2>/dev/null || true
	@echo stopped

smoke: ## LLM 不要の疎通テスト（カード取得・URL整合・カード解決）
	@ADK_SUPPRESS_A2A_EXPERIMENTAL_FEATURE_WARNINGS=true \
	 RECEIPT_AGENT_URL=http://localhost:$(RECEIPT_PORT) \
	 POLICY_AGENT_URL=http://localhost:$(POLICY_PORT) \
	 $(PY) tests/smoke_test.py

card: ## 両エージェントのカードを表示
	@curl -s localhost:$(RECEIPT_PORT)/.well-known/agent-card.json | $(PY) -m json.tool
	@curl -s localhost:$(POLICY_PORT)/.well-known/agent-card.json | $(PY) -m json.tool

chat: ## adk web でオーケストレータと対話（要 GOOGLE_API_KEY）
	$(ADK) web .

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
	$(ADK) api_server --a2a --port $(RECEIPT_PORT) agents

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
