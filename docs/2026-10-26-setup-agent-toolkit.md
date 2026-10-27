# Configuração do Agent Toolkit for AWS — 2026-10-26

Instruções seguidas: https://raw.githubusercontent.com/aws/agent-toolkit-for-aws/refs/heads/main/setup-instructions/setup.md

- **Profile:** `aws-agent`
- **Experiência:** nova experiência da AWS (projeto)
- **Região do projeto:** us-east-2
- **Projeto:** 019141478952

## O que foi feito

1. **AWS CLI:** instalado o AWS CLI 2.38.6 em `~/.local/bin`, que já está no PATH via `~/.profile`.
2. **Login:** `aws configure set region us-east-2` + `aws login` no profile `aws-agent`, com acesso validado por `aws sts get-caller-identity`. As credenciais valem 12 horas e podem ser renovadas por 90 dias sem entrar de novo pelo navegador.
3. **Agent Toolkit:** `aws configure agent-toolkit --yes --region us-east-1` (o serviço só existe em us-east-1).
   - 24 skills padrão instaladas para Claude Code, Cline, Codex e Cursor.
   - Servidor MCP `aws-mcp` configurado em `~/.claude.json`, `~/.cline/mcp.json`, `~/.cursor/mcp.json` e `~/.gemini/settings.json`.
   - O Codex ficou sem MCP, porque o comando `codex` não está no PATH.
4. **Profile no MCP:** adicionado `"env": {"AWS_MCP_PROXY_PROFILES": "aws-agent"}` a cada entrada `aws-mcp`. Uma cópia de cada arquivo original foi salva com o sufixo `.bak-agent-toolkit`.
5. **Verificação:** `aws agent-toolkit list-available-skills` retornou 117 skills.
6. **Regras:** as regras da nova experiência (`aws-starter-rules.md`) foram adicionadas ao `CLAUDE.md`, entre os marcadores `<!-- BEGIN/END AWS Agent Toolkit rules -->`.

## Reautenticar

Quando aparecer `Your session has expired`, rode o comando abaixo e confirme no navegador:

```bash
aws login --profile aws-agent --region us-east-2
```

Sem navegador nesta máquina, adicione `--remote` para receber um link e abri-lo em outro dispositivo. Depois do login, reinicie o Claude Code: o servidor `aws-mcp` falha com o erro `-32602` se iniciar com a sessão expirada.

## Usar outro projeto AWS

Rode `aws login --profile <nome>`, inclua esse nome na lista `AWS_MCP_PROXY_PROFILES` (separando por espaço) de cada arquivo de configuração MCP e reinicie a ferramenta.
