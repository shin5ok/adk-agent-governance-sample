#!/usr/bin/env python3
"""receipt / policy / orchestrator を Agent Runtime に Agent Identity 付きでデプロイする。

必要: pip install "google-cloud-aiplatform[adk,agent_engines]"
環境変数: GOOGLE_CLOUD_PROJECT, GOOGLE_CLOUD_LOCATION, STAGING_BUCKET
オプション: AGENT_GATEWAY（projects/.../agentGateways/... を渡すと経路をゲートウェイに固定）
"""
import os

import vertexai
from vertexai import types
from vertexai.agent_engines import AdkApp

from agents.receipt_agent.agent import root_agent as receipt_agent
from agents.policy_agent.agent import root_agent as policy_agent
from orchestrator.agent import root_agent as orchestrator

PROJECT = os.environ["GOOGLE_CLOUD_PROJECT"]
LOCATION = os.environ.get("GOOGLE_CLOUD_LOCATION", "us-central1")
BUCKET = os.environ["STAGING_BUCKET"]
GATEWAY = os.environ.get("AGENT_GATEWAY", "")

client = vertexai.Client(
    project=PROJECT, location=LOCATION, http_options=dict(api_version="v1beta1")
)


def deploy(agent, name: str, through_gateway: bool = False):
    config: dict = {
        "display_name": name,
        "identity_type": types.IdentityType.AGENT_IDENTITY,  # 身分証を配る
        "requirements": ["google-cloud-aiplatform[adk,agent_engines]"],
        "staging_bucket": f"gs://{BUCKET}",
    }
    if through_gateway and GATEWAY:
        # egress をゲートウェイ経由に固定（Model Armor / ツール単位 IAM が効く）
        config["agent_gateway_config"] = {
            "agent_to_anywhere_config": {"agent_gateway": GATEWAY}
        }
        config["env_vars"] = {
            "GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES": False,
        }
    app = client.agent_engines.create(agent=AdkApp(agent=agent), config=config)
    identity = app.api_resource.spec.effective_identity
    print(f"{name}: deployed. identity = {identity}")
    return app


if __name__ == "__main__":
    deploy(receipt_agent, "receipt-agent")
    deploy(policy_agent, "policy-agent")
    deploy(orchestrator, "expense-orchestrator", through_gateway=True)
