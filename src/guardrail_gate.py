"""Guardrail gate — first node in the flow, screens the raw customer message.

Runs Bedrock ApplyGuardrail (content filters + prompt-attack detection) on the
customer message BEFORE any model processes it. Attaching the guardrail to the
prompt nodes directly does not work: the flow scans the entire rendered
template, and the classifier's own anti-injection instructions trip the
PROMPT_ATTACK filter, blocking every request. Screening only the raw message
here avoids that while blocking genuinely harmful or injecting inputs.

Returns the message unchanged when it passes, or the blocked-message text when
the guardrail intervenes (the LabelNormalizer routes that to BlockedOutput).
"""

import json
import os

import boto3

bedrock_runtime = boto3.client("bedrock-runtime")

GUARDRAIL_ID = os.environ["GUARDRAIL_ID"]
GUARDRAIL_VERSION = os.environ["GUARDRAIL_VERSION"]
BLOCKED_MESSAGE = os.environ["BLOCKED_MESSAGE"]


def lambda_handler(event, _):
    print("EVENT:", json.dumps(event, default=str))

    message = ""
    for node_input in event.get("node", {}).get("inputs", []):
        if node_input.get("name") == "codeHookInput":
            message = str(node_input.get("value") or "")
            break

    if not message.strip():
        return BLOCKED_MESSAGE

    resp = bedrock_runtime.apply_guardrail(
        guardrailIdentifier=GUARDRAIL_ID,
        guardrailVersion=GUARDRAIL_VERSION,
        source="INPUT",
        content=[{"text": {"text": message}}],
    )
    if resp.get("action") == "GUARDRAIL_INTERVENED":
        print("GUARDRAIL_INTERVENED:", json.dumps(resp.get("assessments"), default=str))
        return BLOCKED_MESSAGE

    return message
