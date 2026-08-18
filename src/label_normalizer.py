"""Normalizes classifier output so the Condition node only ever sees valid labels.

Sits between the Classifier prompt node and the Router condition node as a
Lambda node. Guarantees the router input is exactly one of BUG, FAQ, OTHER,
or BLOCKED (when the guardrail intervened at the classifier), regardless of
any whitespace, punctuation, or casing drift in the model output.
"""

import json
import os

VALID_LABELS = {"BUG", "FAQ", "OTHER"}
BLOCKED_MESSAGE = os.environ["BLOCKED_MESSAGE"]


def lambda_handler(event, _):
    print("EVENT:", json.dumps(event, default=str))

    raw, gate_output = "", ""
    for node_input in event.get("node", {}).get("inputs", []):
        if node_input.get("name") == "codeHookInput":
            raw = str(node_input.get("value") or "")
        elif node_input.get("name") == "gateOutput":
            gate_output = str(node_input.get("value") or "")

    if gate_output.strip() == BLOCKED_MESSAGE.strip():
        return "BLOCKED"

    label = "".join(c for c in raw if c.isalpha()).upper()
    return label if label in VALID_LABELS else "OTHER"
