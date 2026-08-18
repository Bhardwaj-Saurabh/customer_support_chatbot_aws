"""Adapter between a Bedrock Flows Lambda node and the create-bug-report tool.

Bedrock Agents (Classic) is in maintenance mode for accounts without prior
usage, so this project's bug path uses a Prompt node that extracts the bug
fields as JSON, followed by a Lambda node that invokes this function. It
translates the flow-node payload into the agent-style event the original
create-bug-report Lambda expects, so the starter tool stays unchanged.
"""

import json
import os

import boto3

lambda_client = boto3.client("lambda")

BUG_TOOL_FUNCTION = os.environ["BUG_TOOL_FUNCTION"]

FOLLOW_UP = (
    "I'm sorry you're running into trouble. To create a ticket for our "
    "engineering team, could you describe what went wrong, the steps to "
    "reproduce it, and your environment (browser, OS, or device)?"
)


def lambda_handler(event, _):
    print("EVENT:", json.dumps(event, default=str))

    raw = ""
    for node_input in event.get("node", {}).get("inputs", []):
        if node_input.get("name") == "codeHookInput":
            raw = node_input.get("value") or ""
            break

    details = _parse_json(raw)
    description = (details.get("description") or "").strip()
    if not description:
        return FOLLOW_UP

    agent_event = {
        "messageVersion": "1.0",
        "function": "create_bug_report",
        "actionGroup": "bug-report-actions",
        "sessionId": "flow-session",
        "agent": {"id": "flow-lambda-node", "alias": "flow"},
        "parameters": [
            {"name": "description", "value": description},
            {"name": "stepsToReproduce", "value": (details.get("stepsToReproduce") or "").strip()},
            {"name": "environment", "value": (details.get("environment") or "").strip()},
        ],
    }

    resp = lambda_client.invoke(
        FunctionName=BUG_TOOL_FUNCTION,
        Payload=json.dumps(agent_event).encode("utf-8"),
    )
    payload = json.loads(resp["Payload"].read())
    body = json.loads(
        payload["response"]["functionResponse"]["responseBody"]["TEXT"]["body"]
    )

    if "ticketId" in body:
        return (
            "Thanks for reporting this! I've created a support ticket for our "
            f"engineering team. Your ticket ID is {body['ticketId']} and its "
            "status is OPEN. We'll follow up as soon as possible."
        )
    return FOLLOW_UP


def _parse_json(raw):
    """Parse the extractor model's output, tolerating code fences."""
    if isinstance(raw, dict):
        return raw
    text = str(raw).strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text[text.find("{"):]
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1:
        return {}
    try:
        return json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return {}
