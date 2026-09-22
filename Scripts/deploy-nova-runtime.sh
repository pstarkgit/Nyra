#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_PROFILE="${NYRA_SOURCE_PROFILE:-}"
RUNTIME_PROFILE="${NYRA_NOVA_PROFILE:-nyra-nova}"
REGION="${NYRA_AWS_REGION:-us-west-2}"
STACK_NAME="${NYRA_NOVA_STACK_NAME:-NyraNovaRuntime}"
TRUSTED_ROLE_NAME="${NYRA_TRUSTED_ROLE_NAME:-Admin}"
MODEL_ID="amazon.nova-2-sonic-v1:0"

if test -z "$SOURCE_PROFILE"; then
  echo "NYRA_SOURCE_PROFILE must name an MCS-backed AWS profile." >&2
  exit 2
fi

ACCOUNT_ID="$(
  /usr/bin/env aws sts get-caller-identity \
    --profile "$SOURCE_PROFILE" \
    --query Account \
    --output text
)"
case "$ACCOUNT_ID" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "AWS returned an invalid account ID." >&2; exit 1 ;;
esac

/usr/bin/env aws cloudformation deploy \
  --profile "$SOURCE_PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$ROOT_DIR/infra/nyra-nova.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "TrustedRoleName=$TRUSTED_ROLE_NAME" \
    "RuntimeRegion=$REGION" \
  --no-fail-on-empty-changeset

ROLE_ARN="$(
  /usr/bin/env aws cloudformation describe-stacks \
    --profile "$SOURCE_PROFILE" \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='RuntimeRoleArn'].OutputValue | [0]" \
    --output text
)"
MODEL_ARN="$(
  /usr/bin/env aws cloudformation describe-stacks \
    --profile "$SOURCE_PROFILE" \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='FoundationModelArn'].OutputValue | [0]" \
    --output text
)"
expected_role_arn="arn:aws:iam::$ACCOUNT_ID:role/NyraNovaRuntime"
expected_model_arn="arn:aws:bedrock:$REGION::foundation-model/$MODEL_ID"
if test "$ROLE_ARN" != "$expected_role_arn"; then
  echo "Unexpected runtime role ARN: $ROLE_ARN" >&2
  exit 1
fi
if test "$MODEL_ARN" != "$expected_model_arn"; then
  echo "Unexpected foundation model ARN: $MODEL_ARN" >&2
  exit 1
fi

/usr/bin/env aws configure set region "$REGION" --profile "$RUNTIME_PROFILE"
/usr/bin/env aws configure set role_arn "$ROLE_ARN" --profile "$RUNTIME_PROFILE"
/usr/bin/env aws configure set source_profile "$SOURCE_PROFILE" --profile "$RUNTIME_PROFILE"
/usr/bin/env aws configure set role_session_name nyra-nova-local --profile "$RUNTIME_PROFILE"

/usr/bin/env aws sts get-caller-identity \
  --profile "$RUNTIME_PROFILE" \
  --query '{Account:Account,Arn:Arn}' \
  --output json

printf 'Configured AWS profile %s for Nyra Nova 2 Sonic in %s.\n' \
  "$RUNTIME_PROFILE" "$REGION"
