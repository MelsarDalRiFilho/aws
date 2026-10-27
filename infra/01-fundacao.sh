#!/usr/bin/env bash
# Fase 1: chave KMS do payload, buckets S3 raw/nok e tabelas DynamoDB. Idempotente.
set -euo pipefail
source "$(dirname "$0")/config.sh"

# --- KMS assimétrica para o payload vindo do celular ---
KMS_ALIAS=alias/${PREFIX}-payload
if ! aws kms describe-key --key-id "$KMS_ALIAS" >/dev/null 2>&1; then
  KEY_ID=$(aws kms create-key \
    --key-spec RSA_4096 --key-usage ENCRYPT_DECRYPT \
    --description "Payload criptografado dos dispositivos (${PREFIX})" \
    --tags TagKey=Project,TagValue=ingest TagKey=Env,TagValue=dev \
    --query KeyMetadata.KeyId --output text)
  aws kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$KEY_ID"
  echo "KMS criada: $KEY_ID ($KMS_ALIAS)"
else
  echo "KMS já existe: $KMS_ALIAS"
fi

# --- Buckets S3 ---
for kind in raw nok; do
  BUCKET=${PREFIX}-${kind}-${ACCOUNT_ID}
  if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    echo "Bucket criado: $BUCKET"
  else
    echo "Bucket já existe: $BUCKET"
  fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
    "Rules":[{"ID":"expira-poc","Status":"Enabled","Filter":{},
      "Expiration":{"Days":30},
      "NoncurrentVersionExpiration":{"NoncurrentDays":7},
      "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}'
  aws s3api put-bucket-tagging --bucket "$BUCKET" \
    --tagging 'TagSet=[{Key=Project,Value=ingest},{Key=Env,Value=dev}]'
done

# --- DynamoDB ---
create_table() {
  local name=$1; shift
  if ! aws dynamodb describe-table --table-name "$name" >/dev/null 2>&1; then
    aws dynamodb create-table --table-name "$name" --billing-mode PAY_PER_REQUEST \
      --tags $TAGS "$@" >/dev/null
    aws dynamodb wait table-exists --table-name "$name"
    echo "Tabela criada: $name"
  else
    echo "Tabela já existe: $name"
  fi
}

create_table ${PREFIX}-devices \
  --attribute-definitions AttributeName=deviceId,AttributeType=S \
  --key-schema AttributeName=deviceId,KeyType=HASH

create_table ${PREFIX}-data \
  --attribute-definitions AttributeName=deviceId,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=deviceId,KeyType=HASH AttributeName=sk,KeyType=RANGE
