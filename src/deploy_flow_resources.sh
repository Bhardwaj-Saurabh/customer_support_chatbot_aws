#!/usr/bin/env bash
# Rebuilds all chatbot resources in the current AWS account (idempotent-ish:
# intended for a FRESH lab account after a Vocareum rotation).
#
# Prereqs: cloudformation-tool.yaml already deployed (bug-report-tool-stack),
# AWS CLI configured for us-east-1. Run from the src/ directory:
#   bash deploy_flow_resources.sh
#
# Prints the flow ID and alias ID at the end — use them with
# generate-eval-dataset.py.

set -euo pipefail
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BLOCKED_MSG="I'm sorry, but I can't help with that request. If you need assistance, please call our support line at +1-800-555-0199."
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "== Account: $ACCOUNT =="

BUG_TOOL_ARN=$(aws cloudformation describe-stacks --stack-name bug-report-tool-stack \
  --query "Stacks[0].Outputs[?OutputKey=='LambdaFunctionArn'].OutputValue" --output text --region $REGION)
BUG_TOOL_NAME=${BUG_TOOL_ARN##*:}
echo "== Bug tool Lambda: $BUG_TOOL_NAME =="

cat > "$WORKDIR/lambda-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > "$WORKDIR/bedrock-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

create_role() { # name trust-file
  aws iam get-role --role-name "$1" >/dev/null 2>&1 || \
    aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" --query 'Role.Arn' --output text
}

echo "== Guardrail =="
GUARDRAIL_ID=$(aws bedrock list-guardrails --region $REGION \
  --query "guardrails[?name=='chatbot-guardrail'].id" --output text)
if [ -z "$GUARDRAIL_ID" ]; then
  GUARDRAIL_ID=$(aws bedrock create-guardrail --name chatbot-guardrail \
    --description "Blocks harmful content and prompt injection for the customer support chatbot" \
    --blocked-input-messaging "$BLOCKED_MSG" --blocked-outputs-messaging "$BLOCKED_MSG" \
    --content-policy-config '{"filtersConfig":[
      {"type":"PROMPT_ATTACK","inputStrength":"HIGH","outputStrength":"NONE"},
      {"type":"HATE","inputStrength":"HIGH","outputStrength":"HIGH"},
      {"type":"VIOLENCE","inputStrength":"HIGH","outputStrength":"HIGH"},
      {"type":"SEXUAL","inputStrength":"HIGH","outputStrength":"HIGH"},
      {"type":"INSULTS","inputStrength":"HIGH","outputStrength":"HIGH"},
      {"type":"MISCONDUCT","inputStrength":"HIGH","outputStrength":"HIGH"}]}' \
    --region $REGION --query 'guardrailId' --output text)
  aws bedrock create-guardrail-version --guardrail-identifier "$GUARDRAIL_ID" --region $REGION >/dev/null
fi
echo "Guardrail: $GUARDRAIL_ID"

deploy_lambda() { # function-name source-file role-name env-json
  cp "$2" "$WORKDIR/index.py"
  (cd "$WORKDIR" && zip -q -FS lambda.zip index.py)
  if aws lambda get-function --function-name "$1" --region $REGION >/dev/null 2>&1; then
    aws lambda update-function-code --function-name "$1" --zip-file "fileb://$WORKDIR/lambda.zip" --region $REGION >/dev/null
  else
    aws lambda create-function --function-name "$1" --runtime python3.12 \
      --handler index.lambda_handler --role "arn:aws:iam::$ACCOUNT:role/$3" \
      --environment "$4" --zip-file "fileb://$WORKDIR/lambda.zip" --timeout 15 \
      --region $REGION >/dev/null
    aws lambda add-permission --function-name "$1" --statement-id bedrock-invoke \
      --action lambda:InvokeFunction --principal bedrock.amazonaws.com --region $REGION >/dev/null
  fi
  echo "Lambda: $1"
}

echo "== Roles =="
create_role bug-tool-wrapper-role "$WORKDIR/lambda-trust.json"
aws iam attach-role-policy --role-name bug-tool-wrapper-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name bug-tool-wrapper-role --policy-name InvokeBugTool --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":\"$BUG_TOOL_ARN\"}]}"

create_role label-normalizer-role "$WORKDIR/lambda-trust.json"
aws iam attach-role-policy --role-name label-normalizer-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

create_role guardrail-gate-role "$WORKDIR/lambda-trust.json"
aws iam attach-role-policy --role-name guardrail-gate-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name guardrail-gate-role --policy-name ApplyGuardrail --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"bedrock:ApplyGuardrail\",\"Resource\":\"arn:aws:bedrock:$REGION:$ACCOUNT:guardrail/$GUARDRAIL_ID\"}]}"

create_role chatbot-flow-role "$WORKDIR/bedrock-trust.json"
aws iam put-role-policy --role-name chatbot-flow-role --policy-name FlowPerms --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":\"bedrock:InvokeModel\",\"Resource\":\"arn:aws:bedrock:$REGION::foundation-model/*\"},
    {\"Effect\":\"Allow\",\"Action\":\"lambda:InvokeFunction\",\"Resource\":[\"arn:aws:lambda:$REGION:$ACCOUNT:function:flow-bug-tool-wrapper\",\"arn:aws:lambda:$REGION:$ACCOUNT:function:flow-label-normalizer\",\"arn:aws:lambda:$REGION:$ACCOUNT:function:flow-guardrail-gate\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"bedrock:GetFlow\",\"bedrock:GetPrompt\"],\"Resource\":\"*\"}]}"

echo "Waiting for IAM propagation..." && sleep 10

echo "== Lambdas =="
deploy_lambda flow-bug-tool-wrapper flow_bug_tool_wrapper.py bug-tool-wrapper-role \
  "{\"Variables\":{\"BUG_TOOL_FUNCTION\":\"$BUG_TOOL_NAME\"}}"
deploy_lambda flow-label-normalizer label_normalizer.py label-normalizer-role \
  "{\"Variables\":{\"BLOCKED_MESSAGE\":\"$BLOCKED_MSG\"}}"
deploy_lambda flow-guardrail-gate guardrail_gate.py guardrail-gate-role \
  "{\"Variables\":{\"GUARDRAIL_ID\":\"$GUARDRAIL_ID\",\"GUARDRAIL_VERSION\":\"1\",\"BLOCKED_MESSAGE\":\"$BLOCKED_MSG\"}}"

echo "== Flow definition =="
export WRAPPER_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:flow-bug-tool-wrapper"
export NORMALIZER_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:flow-label-normalizer"
export GATE_LAMBDA_ARN="arn:aws:lambda:$REGION:$ACCOUNT:function:flow-guardrail-gate"
python3 build_flow_definition.py

echo "== Flow =="
FLOW_ID=$(aws bedrock-agent list-flows --region $REGION \
  --query "flowSummaries[?name=='customer-support-chatbot'].id" --output text)
if [ -z "$FLOW_ID" ]; then
  FLOW_ID=$(aws bedrock-agent create-flow --name customer-support-chatbot \
    --description "Classifies customer messages (BUG/FAQ/OTHER) and routes to bug-ticket tool, FAQ answering, or human redirect" \
    --execution-role-arn "arn:aws:iam::$ACCOUNT:role/chatbot-flow-role" \
    --definition file://flow-definition.json --region $REGION --query 'id' --output text)
else
  aws bedrock-agent update-flow --flow-identifier "$FLOW_ID" --name customer-support-chatbot \
    --description "Classifies customer messages (BUG/FAQ/OTHER) and routes to bug-ticket tool, FAQ answering, or human redirect" \
    --execution-role-arn "arn:aws:iam::$ACCOUNT:role/chatbot-flow-role" \
    --definition file://flow-definition.json --region $REGION >/dev/null
fi
aws bedrock-agent prepare-flow --flow-identifier "$FLOW_ID" --region $REGION >/dev/null
sleep 8
aws bedrock-agent get-flow --flow-identifier "$FLOW_ID" --region $REGION --query 'status' --output text

VERSION=$(aws bedrock-agent create-flow-version --flow-identifier "$FLOW_ID" --region $REGION --query 'version' --output text)
ALIAS_ID=$(aws bedrock-agent list-flow-aliases --flow-identifier "$FLOW_ID" --region $REGION \
  --query "flowAliasSummaries[?name=='v1'].id" --output text)
if [ -z "$ALIAS_ID" ]; then
  ALIAS_ID=$(aws bedrock-agent create-flow-alias --flow-identifier "$FLOW_ID" --name v1 \
    --routing-configuration "[{\"flowVersion\":\"$VERSION\"}]" --region $REGION --query 'id' --output text)
else
  aws bedrock-agent update-flow-alias --flow-identifier "$FLOW_ID" --alias-identifier "$ALIAS_ID" --name v1 \
    --routing-configuration "[{\"flowVersion\":\"$VERSION\"}]" --region $REGION >/dev/null
fi

echo ""
echo "=============================================="
echo "FLOW_ID:       $FLOW_ID"
echo "FLOW_ALIAS_ID: $ALIAS_ID"
echo "FLOW_VERSION:  $VERSION"
echo "GUARDRAIL_ID:  $GUARDRAIL_ID"
echo "=============================================="
