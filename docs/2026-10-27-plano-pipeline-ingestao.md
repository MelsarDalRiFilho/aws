# Plano — Pipeline de ingestão de dados de dispositivos móveis

Status: **Fase 2 concluída.**

## Recursos criados
| Fase | Recurso | ID / nome |
|---|---|---|
| 1 | KMS RSA_4096 ENCRYPT_DECRYPT | `70912db1-817a-4a37-9206-b72271d39cbb` (`alias/ingest-payload`) |
| 1 | S3 raw (SSE-S3, versionado, expira em 30d) | `ingest-raw-019141478952` |
| 1 | S3 nok (idem) | `ingest-nok-019141478952` |
| 1 | DynamoDB cadastro (PK `deviceId`) | `ingest-devices` |
| 1 | DynamoDB dados finais (PK `deviceId`, SK `sk` = `<timestamp>#<messageId>`) | `ingest-data` |

| 2 | SQS ingestão (visibility 180s, retenção 4d, SSE-SQS, redrive 3x) | `ingest-queue` |
| 2 | SQS DLQ (retenção 14d) | `ingest-queue-dlq` |
| 2 | IAM role (só `sqs:SendMessage` em `ingest-queue`) | `ingest-apigw-sqs-role` |
| 2 | API REST regional, stage `dev` | `025tr6hq7g` → `https://025tr6hq7g.execute-api.us-east-2.amazonaws.com/dev/ingest` |
| 2 | Usage plan (10 rps, burst 20, 10.000/dia) | `dvl1xp` |
| 2 | API Key | `0wxuggrnvl` (`ingest-key`) |

Scripts: `infra/01-fundacao.sh`, `infra/02-entrada.sh` (idempotentes). Decisões: S3 com SSE-S3 (sem KMS própria); PITR desligado no POC; payload limitado a 200.000 caracteres em `ct`; uma API Key única.

### Contrato da API (Fase 2)
`POST /ingest`, headers `x-api-key` e `Content-Type: application/json`. Corpo (envelope, base64):
`{"v":1, "ek":<chave AES cifrada RSA-OAEP-SHA256>, "iv":<12 bytes>, "tag":<16 bytes GCM>, "ct":<payload AES-256-GCM>}`
Respostas: 200 `{"messageId"}` · 400 corpo inválido/>200k · 403 sem chave · 415 content-type · 429 throttling · 502 falha no SQS.

### Comandos úteis
```bash
source infra/config.sh
aws apigateway get-api-key --api-key 0wxuggrnvl --include-value --query value --output text   # valor da chave (não versionar)
aws apigateway test-invoke-method --rest-api-id 025tr6hq7g --resource-id <id> --http-method POST --body '...'  # log da integração
```

### Lições da Fase 2
- A associação da API Key ao Usage Plan leva cerca de 1 min para propagar (403 até lá). Um deploy novo leva alguns segundos.
- O API Gateway não envia `aws:SourceAccount` ao assumir a role de integração; essa condição na trust policy causa "does not have permission to assume the provided role".
- Template de resposta: use `$input.json('$.path')`, porque o `$input.path` sem aspas quebra o JSON ("Unable to transform response").
Região: us-east-2 (confirmar em AWS Settings > View all projects > Overview > Additional Info > Region)
Linguagem: Node.js 22.x (CommonJS, AWS SDK JS v3) · Provisionamento: AWS CLI

## Arquitetura alvo

```
Celular --HTTPS POST (JSON criptografado)--> API Gateway (REST, API Key + Usage Plan)
  --> SQS ingest (+DLQ) --> Lambda raw-writer --> S3 raw/
  --> (S3 Event Notification) --> Lambda decrypt-validate (KMS)
        ├─ NOK --> SQS nok (+DLQ) --> Lambda nok-writer --> S3 nok/
        └─ OK  --> Lambda enrich (ElastiCache, dentro da VPC) --> DynamoDB
CloudWatch: logs, métricas, alarmes e dashboard em todas as etapas
```

Convenção de nomes: prefixo `ingest-` (ex.: `ingest-queue`, `ingest-raw-writer`).
Tags em tudo: `Project=ingest`, `Env=dev`.

## Fases

### Fase 0 — Pré-requisitos e decisões
- Verificar plano (`aws freetier get-account-plan-state`) e spend limit.
- Confirmar Região e responder as decisões em aberto (abaixo).
- Criar estrutura do repositório: `infra/` (scripts CLI `.sh` idempotentes), `src/<lambda>/`, `test/`.
- **Pronto quando:** decisões registradas aqui.

### Fase 1 — Fundação: segurança e armazenamento
- Chave KMS (simétrica ou assimétrica, conforme decisão), alias `alias/ingest`.
- Buckets S3: `ingest-raw-<accountId>`, `ingest-nok-<accountId>` — Block Public Access, SSE-KMS, versionamento, lifecycle (ex.: Glacier após 30 dias).
- Tabela DynamoDB `ingest-data` (on-demand, PITR ativado).
- **Pronto quando:** `aws s3api get-bucket-encryption` e `aws dynamodb describe-table` confirmam a configuração.

### Fase 2 — Entrada: API Gateway → SQS
- Fila `ingest-queue` + DLQ `ingest-queue-dlq` (maxReceiveCount=3).
- Role IAM para o API Gateway com permissão apenas de `sqs:SendMessage` nessa fila.
- REST API com integração direta com SQS (sem Lambda no meio), `POST /ingest`, API Key obrigatória, Usage Plan com throttling e cota.
- Validação de request (tamanho e content-type) no próprio API Gateway.
- **Pronto quando:** `curl` com API Key retorna 200 e a mensagem aparece na fila; sem a chave retorna 403.

### Fase 3 — Lambda raw-writer (SQS → S3)
- Código Node.js: lê lote do SQS e grava `raw/AAAA/MM/DD/<messageId>.json`. Usa `ReportBatchItemFailures`.
- Role com privilégio mínimo (sqs receive/delete, s3:PutObject no prefixo, kms:GenerateDataKey).
- Event Source Mapping SQS → Lambda.
- **Pronto quando:** POST na API gera um objeto no S3 raw.

### Fase 4 — Lambda decrypt-validate (S3 → KMS → OK/NOK)
- Gatilho: S3 Event Notification (ou S3 → SQS → Lambda, para ter retry/DLQ — ver decisões).
- Descriptografa com KMS, valida o schema (JSON Schema com `ajv`).
- NOK → envia para `ingest-nok-queue` com o motivo do erro. OK → invoca/encaminha para o enriquecimento.
- **Pronto quando:** payload válido segue para o enriquecimento e payload inválido cai na fila NOK com o motivo.

### Fase 5 — Caminho NOK
- `ingest-nok-queue` + DLQ, Lambda `ingest-nok-writer` → `s3://ingest-nok-.../nok/AAAA/MM/DD/`.
- **Pronto quando:** payload inválido vira um objeto no bucket NOK.

### Fase 6 — Enriquecimento via cadastro no DynamoDB
- Tabela `ingest-devices` (cadastro, chave `deviceId`). Sem VPC.
- Lambda `ingest-enrich`: `GetItem` no cadastro e mescla com o payload. Dispositivo desconhecido → NOK. Grava em `ingest-data` (escrita idempotente com `ConditionExpression`).
- **Pronto quando:** item enriquecido aparece em `ingest-data`; dispositivo sem cadastro cai no NOK.

### Fase 7 — Observabilidade (CloudWatch)
- Retenção de logs (ex.: 14 dias) em todos os log groups; logs estruturados em JSON.
- Alarmes: mensagens na DLQ > 0, erros/throttles de Lambda, idade da mensagem mais antiga no SQS, 5XX/4XX no API Gateway.
- Dashboard `ingest` e notificação por SNS/e-mail.
- **Pronto quando:** um erro forçado dispara o alarme e o e-mail chega.

### Fase 8 — Teste ponta a ponta, custos e limpeza
- Script cliente simulando o celular (criptografa e faz o POST).
- Teste de carga leve, revisão de custos, documentação final.
- Decidir: manter ou remover os recursos (script `infra/teardown.sh`).

## Pontos de atenção (help level HIGH)
1. **Criptografia no celular:** o dispositivo não deve ter credencial AWS para chamar o KMS. Alternativas: (a) chave KMS **assimétrica RSA** — o app usa só a chave pública, cifrando uma chave AES aleatória (envelope encryption), e só a Lambda descriptografa; (b) chave simétrica compartilhada no app (inseguro); (c) apenas TLS + criptografia no servidor.
2. **API Key não é autenticação forte:** ela serve para controle de uso/cota e pode ser extraída do app. Para identificar o dispositivo, considerar Cognito/JWT ou assinatura HMAC por dispositivo.
3. **API Key exige REST API** (HTTP API não tem esse recurso). A integração direta API GW→SQS elimina uma Lambda.
4. **ElastiCache é o item mais caro e complexo:** exige VPC, coloca a Lambda dentro da VPC e tem custo mínimo (~US$ 12/mês para t4g.micro; Serverless tem cobrança mínima de armazenamento maior). Alternativa: cache em memória na própria Lambda ou uma tabela DynamoDB com TTL atuando como cache.
5. **Etapa S3 → Lambda:** a notificação direta do S3 é assíncrona (2 retries e depois descarte, a menos que haja destino on-failure). S3 → SQS → Lambda dá mais controle.
6. **Lambda NOK separada** poderia ser simplificada: a própria Lambda de validação pode gravar o NOK no S3. Manter a fila desacopla o fluxo e permite reprocessamento.

## Decisões (2026-10-27)
- **Criptografia:** chave KMS assimétrica RSA_4096 (ENCRYPT_DECRYPT). O app cifra o JSON com AES-256-GCM usando uma chave aleatória e cifra essa chave com a chave pública (RSAES_OAEP_SHA_256). A Lambda chama `kms:Decrypt` só para a chave AES.
- **Cache:** **sem ElastiCache e sem tabela de cache.** O enriquecimento lê direto do cadastro `ingest-devices` (o DynamoDB já responde em ms). Sem VPC.
- **Enriquecimento:** cadastro de dispositivo — tabela `ingest-devices` (origem) → cache com TTL → item final em `ingest-data`.
- **Ambiente:** Dev/POC, plano Free — custo mínimo, retenção curta de logs, sem NAT nem VPC.
- **Região confirmada:** us-east-2. Conta 019141478952, plano FREE ativo, US$ 100 de créditos, expira em 2027-04-27.
- Observação: a chave KMS custa ~US$ 1/mês mais as chamadas (assimétrica não entra no free tier de requisições).
