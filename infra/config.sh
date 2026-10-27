# Variáveis comuns aos scripts de infraestrutura. Uso: source infra/config.sh
export AWS_REGION=us-east-2
export AWS_PROFILE=${AWS_PROFILE:-aws-agent}
export ACCOUNT_ID=019141478952
export PREFIX=ingest
export TAGS="Key=Project,Value=ingest Key=Env,Value=dev"
