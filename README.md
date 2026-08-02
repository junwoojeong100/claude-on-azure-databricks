# Claude Code를 Azure Databricks와 Microsoft Foundry에 연결하기

Claude Code를 Azure Databricks Claude 또는 Microsoft Foundry GPT-5.6에 연결하는
실습 가이드입니다.

먼저 아래 표에서 backend와 실행 위치를 선택하세요. Databricks는 네이티브 Anthropic
Messages API에 직접 연결하고, Foundry GPT-5.6은 LiteLLM이 Anthropic Messages와
OpenAI Responses API를 변환합니다.

> 공식 문서 확인: 2026-08-02.
> 모델과 리전 가용성, 쿼터, Preview 기능은 변경될 수 있으므로 운영 적용 전 공식
> 문서를 다시 확인하세요.

## 1. 연결 흐름 선택

### Azure Databricks Claude

| 선택 | 목적 | 가이드 |
| --- | --- | --- |
| 직접 연결 | 개인 PC의 Claude Code에서 Databricks를 바로 호출 | [Databricks 직접 연결](docs/claude-code-databricks.md) |
| 기존 gateway | 조직의 LiteLLM 서버를 통해 Databricks를 호출 | [기존 LiteLLM에서 Databricks 연결](docs/existing-litellm-databricks.md) |

### Microsoft Foundry GPT-5.6

| 선택 | 목적 | 가이드 |
| --- | --- | --- |
| 로컬 검증 | 개인 PC의 LiteLLM을 통해 Foundry를 호출 | [로컬 LiteLLM에서 Foundry 연결](docs/claude-code-foundry-local.md) |
| 기존 gateway | 조직의 LiteLLM 서버를 통해 Foundry를 호출 | [기존 LiteLLM에서 Foundry 연결](docs/existing-litellm-foundry.md) |

각 backend에서 필요한 선택지 하나만 실행합니다. 기존 LiteLLM 서버가 준비되어 있다면
직접 연결이나 로컬 LiteLLM 설정을 먼저 완료할 필요가 없습니다.

> Foundry GPT-5.6은 Claude Code가 OpenAI Responses API를 직접 호출할 수 없으므로
> 로컬과 기존 서버 흐름 모두 LiteLLM의 Anthropic Messages 변환을 사용합니다.

> 한 번에 하나의 Claude Code route만 활성화하세요. `~/.claude/settings.json`의
> `env` 값은 shell 환경변수보다 우선하므로 다른 흐름으로 전환할 때 기존
> `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` 또는 `apiKeyHelper`, model mapping을
> 바꾸고 Claude Code를 다시 시작해야 합니다.

## 2. 5분 연결: 기존 Databricks workspace

다음 세 값이 준비되어 있으면 바로 시작할 수 있습니다.

| 값 | 예 |
| --- | --- |
| Workspace URL | `https://adb-<workspace-id>.<number>.azuredatabricks.net` |
| Databricks credential | 빠른 검증은 PAT, 장기 사용자 인증은 OAuth U2M |
| 호출 가능한 Claude 모델 ID 하나 | `databricks-claude-opus-5` |

아래 예시는 현재 기본 모델인 Opus 5를 사용합니다. Workspace에서 다른 모델만 사용할
수 있다면 `DATABRICKS_MODEL`을 실제 모델 ID로 바꾸세요. 설정 자동화에는 Git과
Python 3.10 이상이 필요합니다.

### 1. Databricks API부터 확인

macOS, Linux 또는 WSL:

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks

export ANTHROPIC_BASE_URL="https://<workspace-host>/serving-endpoints/anthropic"
export ANTHROPIC_AUTH_TOKEN="<databricks-token>"
export DATABRICKS_MODEL="databricks-claude-opus-5"

curl -sS "$ANTHROPIC_BASE_URL/v1/messages" \
  -H "Authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{\"model\":\"$DATABRICKS_MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}"
```

응답의 최상위 `type`이 `message`이면 workspace URL, credential, 모델 ID가 모두
정상입니다. 이 단계가 실패하면 Claude Code 설정을 변경하기 전에 Databricks 권한·리전·
모델 가용성을 먼저 해결하세요.

Windows PowerShell을 포함한 전체 명령은
[Claude Code 연결 가이드](docs/claude-code-databricks.md#2-databricks-api부터-검증)를
참조하세요.

### 2. Claude Code에서 확인

```bash
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1

claude --model "databricks-claude-opus-5[1m]" \
  -p "Reply with exactly: CLAUDE CODE OK" \
  --output-format json
```

`is_error`가 `false`이고 `modelUsage`에 Databricks 모델 ID가 표시되면 연결된 것입니다.
대화형으로 `claude`를 실행한 뒤 `/status`에서 다음 항목도 확인할 수 있습니다.

- `Anthropic base URL`: Databricks workspace의 `/serving-endpoints/anthropic`
- `Auth token`: `ANTHROPIC_AUTH_TOKEN`

### 3. 검증 모델 설정 저장

임시 검증이 끝난 같은 터미널에서 설정 도구를 실행합니다.

```bash
python3 scripts/configure_claude_code.py \
  --scope project \
  --model "$DATABRICKS_MODEL"
```

Windows PowerShell:

```powershell
$env:DATABRICKS_MODEL = 'databricks-claude-opus-5'
py -3 scripts\configure_claude_code.py `
  --scope project `
  --model $env:DATABRICKS_MODEL
```

도구는 현재 프로젝트의 `.claude/settings.local.json`을 백업하고, 앞에서 성공한 모델
하나와 Databricks route만 병합합니다.

## 3. Databricks workspace가 없다면

새 Azure Databricks workspace가 필요할 때만
[Azure Databricks workspace 생성 가이드](docs/azure-databricks-setup.md)를 사용합니다.

macOS, Linux 또는 WSL에서는 다음 스크립트가 리소스 그룹과 Premium classic workspace를
만들고, PAT와 네이티브 Anthropic API를 검증한 뒤 성공한 모델 하나를 현재 프로젝트의
Claude Code 설정에 저장합니다.

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks

az extension add --name databricks --upgrade
az login
az account set --subscription "<name-or-id>"

RG=my-rg LOCATION=eastus2 WORKSPACE=my-workspace \
  scripts/setup_databricks_claude.sh
```

Windows PowerShell:

```powershell
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
Set-Location claude-on-azure-databricks

az extension add --name databricks --upgrade
az login
az account set --subscription '<name-or-id>'

.\scripts\Setup-DatabricksClaude.ps1 `
  -ResourceGroup my-rg `
  -Location eastus2 `
  -Workspace my-workspace
```

> Workspace 생성과 Claude 모델 가용성은 별개입니다. 스크립트는 custom endpoint를
> 배포하지 않으며, 생성된 workspace에서 Databricks-hosted 모델을 실제 호출해 준비 상태를
> 확인합니다.

Claude Code 설정을 변경하지 않으려면 `CONFIGURE_CLAUDE_CODE=0`을 추가하세요.

스크립트 완료 후 새 터미널에서 repository root로 이동해 최종 연결을 확인합니다.

```bash
cd /path/to/claude-on-azure-databricks
claude -p "Reply with exactly: WORKSPACE SETUP OK" --output-format json
```

Windows PowerShell에서는 먼저
`Set-Location C:\path\to\claude-on-azure-databricks`를 실행합니다.

`is_error`가 `false`이고 `modelUsage`에 스크립트가 검증한 Databricks 모델 ID가
표시되어야 합니다. 대화형 `/status`의 Anthropic base URL도 workspace의
`/serving-endpoints/anthropic`이어야 합니다.

## 4. 선택 기능

| 목적 | 가이드 |
| --- | --- |
| PAT를 저장하지 않고 OAuth U2M token 자동 갱신 | [OAuth `apiKeyHelper`](docs/claude-code-databricks.md#6-pat-대신-oauth-u2m) |
| VS Code extension에서 Databricks routing 사용 | [VS Code extension 설정](docs/claude-code-databricks.md#7-vs-code-extension-사용-시) |

## 보안과 비용

- PAT나 OAuth access token을 Git에 커밋하지 마세요.
- PAT는 가장 쉬운 로컬 검증 방법이지만 legacy 인증입니다. 사용자 장기 사용은 OAuth U2M,
  운영 자동화는 OAuth M2M을 사용하세요.
- 로컬 Foundry 실습의 LiteLLM은 `127.0.0.1`에만 bind하고 local key를 공유하지 마세요.
- 기존 LiteLLM에서 Foundry에 연결할 때는 API key 대신 host의 managed identity를
  사용합니다.
- Workspace와 pay-per-token 모델 사용에는 비용이 발생합니다. 실습용 리소스는 사용 후
  [workspace 생성 가이드의 정리 절차](docs/azure-databricks-setup.md#정리)로 삭제하세요.
- Foundry GPT-5.6 호출에도 deployment 유형과 token 사용량에 따른 비용이 발생합니다.
- Foundation Model API의 context window와 workspace 요청 한도는 별개입니다.

## 공식 문서

- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Azure Databricks OAuth U2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-u2m)
- [Azure Databricks personal access tokens](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat#create-personal-access-tokens-for-workspace-users)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
