# 로컬 LiteLLM을 통해 Claude Code를 Microsoft Foundry GPT-5.6에 연결하기

이 문서는 Claude Code와 LiteLLM을 같은 로컬 PC에서 실행해 Microsoft Foundry의
GPT-5.6 Sol 하나를 검증하는 절차입니다. 로컬 연결이 성공한 뒤 조직의 기존
gateway로 전환하려면
[기존 LiteLLM 서버 연결 가이드](existing-litellm-foundry.md)로 진행합니다.

```text
Claude Code
  └─ http://127.0.0.1:4000/v1/messages
      └─ Local LiteLLM
          └─ https://<resource>/openai/v1/responses
              └─ GPT-5.6 deployment
```

> Claude Code는 Foundry GPT-5.6의 OpenAI Responses API를 직접 호출하지 않습니다.
> 이 로컬 LiteLLM은 Anthropic Messages request와 Responses API를 양방향으로
> 변환하는 adapter입니다.

**필수 경로:** Azure CLI 로그인과 설치 → 환경변수와 YAML 작성 → local proxy 시작 →
Sol route 검증 → Claude Code 연결 → 설정 저장

## 1. 준비 사항

다음 항목을 준비합니다.

| 항목 | 확인 위치 또는 값 |
| --- | --- |
| Foundry resource endpoint | Resource의 **Keys and Endpoint** |
| Deployment name | GPT-5.6 Sol deployment의 **Deployment name** |
| 사용자 권한 | Resource 범위의 `Cognitive Services OpenAI User` |
| 로컬 도구 | Azure CLI, Python 3.10 이상, 최신 Claude Code |

이 가이드는 다음 모델 하나만 설정합니다.

| 모델 ID | 모델 버전 | 로컬 LiteLLM alias |
| --- | --- | --- |
| `gpt-5.6-sol` | `2026-07-09` | `foundry-gpt-5.6-sol` |

Model ID와 deployment name은 다를 수 있습니다. LiteLLM 설정에는 portal에 표시된
실제 deployment name을 사용합니다.

Resource에 public network, IP 또는 VNet 제한이 있다면 로컬 PC에서 endpoint에 접근할
수 있어야 합니다. Private endpoint만 사용하는 resource는 VPN, ExpressRoute 또는
허용된 VNet 내부 개발 환경이 필요합니다.

## 2. Azure CLI 로그인과 LiteLLM 설치

Foundry resource가 있는 tenant와 subscription을 선택합니다.

```bash
az login
az account set --subscription "<subscription-name-or-id>"
az account show --query "{subscription:name, tenant:tenantId}" -o table
```

다른 tenant를 사용한다면 `az login --tenant <tenant-id>`로 로그인합니다.

LiteLLM Proxy를 설치합니다.

```bash
python3 -m venv "$HOME/.venvs/litellm-foundry"
source "$HOME/.venvs/litellm-foundry/bin/activate"
python -m pip install --upgrade 'litellm[proxy]'
```

Windows PowerShell:

```powershell
py -3 -m venv "$HOME\.venvs\litellm-foundry"
& "$HOME\.venvs\litellm-foundry\Scripts\Activate.ps1"
python -m pip install --upgrade 'litellm[proxy]'
```

## 3. 로컬 전용 환경변수 설정

macOS, Linux 또는 WSL:

```bash
export LITELLM_MASTER_KEY="$(
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
)"
export FOUNDRY_GPT_API_BASE="https://<resource-name>.openai.azure.com"
export FOUNDRY_GPT_API_VERSION="v1"
export FOUNDRY_GPT_AZURE_SCOPE="https://ai.azure.com/.default"
export AZURE_CREDENTIAL="AzureCliCredential"
```

Windows PowerShell:

```powershell
$env:LITELLM_MASTER_KEY = py -3 -c "import secrets; print(secrets.token_urlsafe(32))"
$env:FOUNDRY_GPT_API_BASE = 'https://<resource-name>.openai.azure.com'
$env:FOUNDRY_GPT_API_VERSION = 'v1'
$env:FOUNDRY_GPT_AZURE_SCOPE = 'https://ai.azure.com/.default'
$env:AZURE_CREDENTIAL = 'AzureCliCredential'
```

Portal에 `*.services.ai.azure.com` endpoint가 표시되면 그 값을 사용해도 됩니다.
`FOUNDRY_GPT_API_BASE`에는 `/openai/v1`, `/responses` 또는 끝의 `/`를 붙이지 않습니다.

`AZURE_CREDENTIAL=AzureCliCredential`은 LiteLLM이 현재 `az login` session을
명시적으로 사용하게 합니다. `AZURE_OPENAI_API_KEY`, `AZURE_API_KEY`,
`AZURE_CLIENT_SECRET`, `AZURE_AD_TOKEN`은 이 터미널에 설정하지 않습니다.
생성한 `LITELLM_MASTER_KEY`는 proxy를 실행하는 동안 이 터미널에만 유지됩니다.

## 4. 로컬 LiteLLM 설정 작성

Git repository 밖의 `$HOME/.config/litellm/foundry-gpt56.yaml`에 다음 설정을
저장하고 placeholder를 실제 deployment name으로 바꿉니다.

```bash
mkdir -p "$HOME/.config/litellm"
```

Windows PowerShell:

```powershell
New-Item -ItemType Directory -Force "$HOME\.config\litellm" | Out-Null
```

```yaml
model_list:
  - model_name: foundry-gpt-5.6-sol
    litellm_params:
      model: azure/responses/<sol-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
      azure_scope: os.environ/FOUNDRY_GPT_AZURE_SCOPE
    model_info:
      base_model: azure/gpt-5.6-sol

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  enable_azure_ad_token_refresh: true
```

로컬 proxy를 loopback interface에서만 시작합니다.

```bash
litellm \
  --config "$HOME/.config/litellm/foundry-gpt56.yaml" \
  --host 127.0.0.1 \
  --port 4000
```

PowerShell에서는 config 경로만 Windows 형식으로 바꿉니다.

```powershell
litellm `
  --config "$HOME\.config\litellm\foundry-gpt56.yaml" `
  --host 127.0.0.1 `
  --port 4000
```

이 터미널은 proxy 실행용으로 유지합니다.

## 5. LiteLLM에서 Sol부터 검증

새 터미널에서 같은 local key를 설정하고 Responses API를 호출합니다.

```bash
export LITELLM_BASE_URL="http://127.0.0.1:4000"
export LITELLM_KEY="$LITELLM_MASTER_KEY"

curl -sS "$LITELLM_BASE_URL/v1/responses" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "content-type: application/json" \
  -d '{
    "model": "foundry-gpt-5.6-sol",
    "input": "Reply with exactly: FOUNDRY SOL LOCAL OK"
  }'
```

Windows PowerShell:

```powershell
$env:LITELLM_BASE_URL = 'http://127.0.0.1:4000'
$env:LITELLM_KEY = $env:LITELLM_MASTER_KEY

$headers = @{ Authorization = "Bearer $env:LITELLM_KEY" }
$body = @{
  model = 'foundry-gpt-5.6-sol'
  input = 'Reply with exactly: FOUNDRY SOL LOCAL OK'
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "$env:LITELLM_BASE_URL/v1/responses" `
  -Headers $headers `
  -ContentType 'application/json' `
  -Body $body
```

## 6. Claude Code를 로컬 LiteLLM에 연결

먼저 현재 shell에서 임시로 설정합니다.

`~/.claude/settings.json`에 기존 Databricks 또는 다른 gateway route가 있으면 그
`env` 값이 shell 환경변수보다 우선합니다. `/status`에 `127.0.0.1:4000`이 아닌 base
URL이 표시되면 설정 파일을 백업한 뒤 기존 `ANTHROPIC_BASE_URL`,
`ANTHROPIC_AUTH_TOKEN` 또는 `apiKeyHelper`, model 값을 제거하고 Claude Code를 다시
시작합니다.

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:4000"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_KEY"
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
```

PowerShell:

```powershell
$env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:4000'
$env:ANTHROPIC_AUTH_TOKEN = $env:LITELLM_KEY
$env:CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = '1'
```

Sol을 Claude Code로 검증합니다.

```bash
claude --model foundry-gpt-5.6-sol \
  -p "Reply with exactly: FOUNDRY SOL CLAUDE CODE LOCAL OK" \
  --output-format json
```

`is_error`가 `false`이고 `modelUsage`에 `foundry-gpt-5.6-sol`이 표시되어야 합니다.

## 7. 설정 저장

검증 후 `~/.claude/settings.json`의 unrelated 설정은 유지하고 다음 값을 병합합니다.

```json
{
  "model": "foundry-gpt-5.6-sol",
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_AUTH_TOKEN": "<generated-local-key>",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

이 리포의 `scripts/configure_claude_code.py`는 Databricks 직접 연결용이므로 실행하지
않습니다. 이전 Databricks 설정의 `model`과 `ANTHROPIC_DEFAULT_*` 값이 남아 있으면
local Foundry 설정으로 교체합니다.

VS Code extension을 사용하면 VS Code 사용자 settings의
`claudeCode.environmentVariables`에도 같은 세 환경변수를 설정합니다.

로컬 proxy가 실행 중이지 않으면 Claude Code 연결도 실패합니다. 상시 운영, 중앙
인증과 여러 사용자 지원이 필요하면 local key나 Azure CLI token을 서버로 복사하지 말고
[기존 LiteLLM 서버에 Foundry GPT-5.6 연결하기](existing-litellm-foundry.md)에서
managed identity 방식으로 전환합니다.

> **완료 기준:** 로컬 LiteLLM이 `127.0.0.1:4000`에서 실행 중이고,
> `foundry-gpt-5.6-sol` Claude Code 테스트가 성공합니다.

다른 흐름으로 전환할 때는 proxy 터미널에서 Ctrl-C를 누르고
`~/.claude/settings.json`의 local Foundry URL, key와 model mapping을 다음 흐름의
값으로 교체합니다. Shell에 export한 값도 새 터미널을 열거나 unset한 뒤 사용합니다.

## 문제 해결

| 증상 | 확인할 항목 |
| --- | --- |
| LiteLLM 시작 실패 | venv 활성화, config 경로, YAML 문법과 환경변수 |
| Foundry `401` | `az login`, `AZURE_CREDENTIAL`, token scope |
| Foundry `403` | 사용자에게 resource 범위의 `Cognitive Services OpenAI User` 역할이 있는지 |
| `404 DeploymentNotFound` | Model ID가 아니라 실제 deployment name을 사용했는지 |
| Network timeout 또는 ACL `403` | Public access, IP allowlist, private endpoint와 DNS |
| Claude Code `401` | local master key와 `ANTHROPIC_AUTH_TOKEN` 일치 여부 |

## 공식 문서

- [LiteLLM에서 non-Anthropic 모델 사용](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)
- [LiteLLM Azure Responses API](https://docs.litellm.ai/docs/providers/azure/azure_responses)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Microsoft Foundry v1 API](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle)
- [Microsoft Foundry Responses API](https://learn.microsoft.com/azure/foundry/openai/how-to/responses)
- [Microsoft Foundry GPT-5.6 모델](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56)
