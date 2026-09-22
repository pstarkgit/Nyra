#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_PROFILE="${NYRA_SOURCE_PROFILE:-}"
RUNTIME_PROFILE="${NYRA_RUNTIME_PROFILE:-nyra-polly}"
REGION="${NYRA_AWS_REGION:-us-west-2}"
STACK_NAME="${NYRA_STACK_NAME:-NyraVoiceRuntime}"
TRUSTED_ROLE_NAME="${NYRA_TRUSTED_ROLE_NAME:-Admin}"

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
  --template-file "$ROOT_DIR/infra/nyra-polly.yaml" \
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
expected_arn="arn:aws:iam::$ACCOUNT_ID:role/NyraPollyRuntime"
if test "$ROLE_ARN" != "$expected_arn"; then
  echo "Unexpected runtime role ARN: $ROLE_ARN" >&2
  exit 1
fi

/usr/bin/env aws configure set region "$REGION" --profile "$RUNTIME_PROFILE"
/usr/bin/env aws configure set role_arn "$ROLE_ARN" --profile "$RUNTIME_PROFILE"
/usr/bin/env aws configure set source_profile "$SOURCE_PROFILE" --profile "$RUNTIME_PROFILE"
/usr/bin/env aws configure set role_session_name nyra-local --profile "$RUNTIME_PROFILE"

/usr/bin/env aws sts get-caller-identity \
  --profile "$RUNTIME_PROFILE" \
  --query '{Account:Account,Arn:Arn}' \
  --output json
/usr/bin/env aws polly describe-voices \
  --profile "$RUNTIME_PROFILE" \
  --region "$REGION" \
  --engine generative \
  --query 'length(Voices)' \
  --output text

printf 'Configured AWS profile %s for Nyra.\n' "$RUNTIME_PROFILE"
