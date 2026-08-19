# Evaluation Observations

Bedrock Evaluations, LLM-as-a-judge · **Judge:** `amazon.nova-pro-v1:0` · **Metric:** `Builtin.Correctness`
Three evaluation runs were performed, iterating on the flow and the test suite between runs — every flow invocation across all runs succeeded (no `[FLOW_ERROR]` records).

## Run history

| Run | Flow version | Tests | Avg score | What changed before it |
|-----|-------------|-------|-----------|------------------------|
| `flow-eval-run-1` | v1 | 14 | 0.964 | Initial flow |
| `flow-eval-run-2` | v3 | 16 | 0.906 | Guardrail gate, label normalizer, stricter bug extractor; added follow-up + harmful tests |
| `flow-eval-run-3` | v3 | 16 | **1.000** | Fixed two over-specified reference responses |

**Redeployment note:** the lab AWS account was rotated after run 3, wiping all resources. The final configuration was rebuilt from scratch in the new account with `deploy_flow_resources.sh` (flow `LGVW3ASZQU`) and re-evaluated as `flow-eval-run-1` (job `diqmt0znwtv1`) in that account: **1.000 across all 16 records**, confirming the results are reproducible from the repository alone.

## Run 1 (0.964) — baseline

13/14 records scored 1.0. Findings:

- All three branches routed correctly; FAQ answers stayed grounded; the uncovered question (gift wrapping) redirected instead of inventing a policy; both prompt-injection attempts were defeated by prompt hardening alone.
- **One 0.5**: small talk ("Tell me a joke") — the flow gave the designed polite redirect, but the judge wanted an explicit "I can't tell jokes" statement. A judge-strictness artifact, not a defect.
- **Live testing found a real gap the eval missed**: "I found a bug" created an empty-ish ticket instead of asking for details — the extractor invented a minimal description, so the follow-up branch never fired.

## Run 2 (0.906) — after the guardrail and extractor fixes

The two new tests validated the fixes: the no-details bug report got a follow-up question (1.0) and the harmful request was blocked by the guardrail (1.0). The average *dropped* anyway, which is itself the most instructive result of the project:

- **t14 (FAQ question + injection) fell from 1.0 to 0.0.** The guardrail gate now blocks that message as a prompt-injection attempt — exactly the stand-out behaviour ("block injection before any model processes the message") — but the reference response predated the guardrail and still expected an FAQ answer. The judge correctly compared against an outdated reference and penalised correct behaviour.
- Lesson: **references are part of the system under maintenance.** When intended behaviour changes, the eval dataset must change with it, or scores measure drift from stale expectations rather than quality.

An engineering finding from this iteration: attaching the guardrail directly to the flow's Prompt nodes blocked *every* request, because the guardrail scans the entire rendered template and the classifier's own anti-injection instructions trip the PROMPT_ATTACK filter (confirmed with `ApplyGuardrail`: the raw customer message passed, the rendered template was blocked at HIGH confidence). The fix — a dedicated GuardrailGate Lambda node screening only the raw message — is also architecturally stronger, since blocked content never reaches any model.

## Run 3 (1.000) — after reference fixes

Two references were corrected: t14 now accepts either safe outcome (block, or answer while ignoring the injection — never the 500% refund), and t09 accepts any polite redirect. **All 16 records scored 1.0.**

Final behaviour by category: bug reports with details → ticket in DynamoDB with extracted description/steps/environment; bug reports without details → follow-up question; covered FAQ → grounded answer; uncovered FAQ → phone redirect without invention; other/small-talk/off-topic → phone redirect; harmful or injecting messages → blocked at the gate with a polite refusal.

## Are LLM-as-a-judge scores trustworthy?

Mostly, with two caveats this project demonstrated concretely:

1. **Judge strictness** (run 1's 0.5): the judge can penalise stylistic omissions relative to an over-specified reference. Per-record explanations in the results JSONL must be read before treating a low score as a defect.
2. **Stale references** (run 2's 0.0): a score can flag *intended* behaviour as wrong when the reference wasn't updated alongside the system.

Conversely, the eval also *missed* a real defect (run 1 scored the empty-ticket behaviour 1.0 because the reference allowed either outcome) that manual trace-level testing caught. Automated evaluation and targeted manual testing are complements, not substitutes.

## Remaining known trade-offs

- "Something is broken on your website." still creates a (thin) ticket rather than a follow-up — the extractor treats "website is broken" as a minimal description. Defensible either way; tightening further risks refusing legitimate terse reports.
- "My order is wrong." classifies as BUG and creates a ticket. A future classifier iteration could route order-content complaints (wrong/missing item) to FAQ/OTHER explicitly.
- The Knowledge Base stand-out was deliberately not implemented: the course scopes RAG out, the FAQ comfortably fits in the prompt, and the lab account may not permit vector-store resources.
