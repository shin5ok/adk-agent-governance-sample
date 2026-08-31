"""expense-orchestrator: 呼ぶ側。

2つのモード:
  - 既定: A2A のカード URL を直接指定（ローカルで完結）
  - USE_AGENT_REGISTRY=1: Agent Registry から解決（要 GCP。名前だけで呼べる）
"""
import os

from google.adk.agents import Agent
from google.adk.agents.remote_a2a_agent import (
    AGENT_CARD_WELL_KNOWN_PATH,
    RemoteA2aAgent,
)

MODEL = os.environ.get("ADK_MODEL", "gemini-3.7-flash")
RECEIPT_URL = os.environ.get("RECEIPT_AGENT_URL", "http://localhost:18001")
POLICY_URL = os.environ.get("POLICY_AGENT_URL", "http://localhost:18002")


def _local_agents() -> list[RemoteA2aAgent]:
    return [
        RemoteA2aAgent(
            name="receipt_agent",
            description="領収書の読み取りと経費データとの突き合わせを担当するリモートエージェント",
            agent_card=f"{RECEIPT_URL}{AGENT_CARD_WELL_KNOWN_PATH}",
            use_legacy=False,
        ),
        RemoteA2aAgent(
            name="policy_agent",
            description="経費規程チェックを担当するリモートエージェント",
            agent_card=f"{POLICY_URL}{AGENT_CARD_WELL_KNOWN_PATH}",
            use_legacy=False,
        ),
    ]


def _registry_agents() -> list[RemoteA2aAgent]:
    # pip install "google-adk[agent-identity]" が必要
    from google.adk.integrations.agent_registry import AgentRegistry

    registry = AgentRegistry(
        project_id=os.environ["GOOGLE_CLOUD_PROJECT"],
        location=os.environ.get("AGENT_REGISTRY_LOCATION", "global"),
    )
    return [
        registry.get_remote_a2a_agent("agents/receipt-agent"),
        registry.get_remote_a2a_agent("agents/policy-agent"),
    ]


sub_agents = (
    _registry_agents()
    if os.environ.get("USE_AGENT_REGISTRY") == "1"
    else _local_agents()
)

root_agent = Agent(
    model=MODEL,
    name="expense_orchestrator",
    instruction=(
        "経費精算のチェック依頼を受け付ける。"
        "領収書の内容確認は receipt_agent に、規程判定は policy_agent に委譲し、"
        "両方の結果が揃ってから、違反があれば理由つきで報告する。"
    ),
    sub_agents=sub_agents,
)
