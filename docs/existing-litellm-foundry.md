# 기존 LiteLLM을 통해 Claude Code를 Microsoft Foundry GPT-5.6에 연결하기

이 가이드는 이미 운영 중인 LiteLLM Proxy에 Microsoft Foundry의 GPT-5.6 Sol, Terra,
Luna를 추가하는 절차입니다. 기존 Databricks와 다른 provider 모델은 그대로 유지하며,
Foundry 인증에는 API key나 service principal 대신 managed identity만 사용합니다.
이 문서는 Foundry 흐름의 2단계입니다. 먼저
[로컬 LiteLLM으로 Claude Code 연결](claude-code-foundry-local.md)을 완료해 resource
endpoint, 실제 deployment name과 Claude Code 호환성을 확인하세요.

> 이 리포는 LiteLLM이나 Foundry resource를 설치하지 않습니다.
> `scripts/configure_claude_code.py`는 **Databricks 직접 연결용**이므로 이 흐름에서는
> 실행하지 않습니다.

```text
Claude Code
  └─ https://<litellm-host>/v1/messages
      └─ LiteLLM model alias
          ├─ foundry-gpt-5.6-sol
          ├─ foundry-gpt-5.6-terra
          └─ foundry-gpt-5.6-luna
```

로컬 LiteLLM과 기존 LiteLLM 서버 연결의 차이는 다음과 같습니다.

| 항목 | 로컬 LiteLLM | 기존 LiteLLM 서버 |
| --- | --- | --- |
| Claude Code endpoint | `http://127.0.0.1:4000` | 조직의 LiteLLM URL |
| Foundry 인증 주체 | `az login`한 로컬 사용자 | LiteLLM host의 managed identity |
| LiteLLM credential | 로컬 master key | 사용자별 virtual key |
| 운영 범위 | 한 사용자 개발·검증 | 중앙 운영과 여러 사용자 |

로컬 key나 Azure CLI token을 기존 서버에 복사하지 않습니다. 또한 Microsoft Learn의
`CLAUDE_CODE_USE_FOUNDRY`, `ANTHROPIC_FOUNDRY_RESOURCE`,
`ANTHROPIC_FOUNDRY_BASE_URL`과 `ANTHROPIC_FOUNDRY_API_KEY`는 Foundry의 Claude
deployment 직접 연결용이므로 GPT-5.6 LiteLLM 흐름에는 설정하지 않습니다.

> 공식 Microsoft Learn과 LiteLLM 문서 확인: 2026-08-01.
>
> 적용 전 기존 `config.yaml`, 환경변수와 database model 설정을 백업하세요.

## 1. Microsoft Foundry deployment 확인

LiteLLM을 시작하는 명령에서 실제 설정 source를 먼저 확인합니다.

```bash
ps -ef | grep '[l]itellm'
```

YAML의 `--config` 경로, systemd `EnvironmentFile`, Docker Compose의 `env_file`,
Kubernetes Secret/ConfigMap 또는 Admin UI 중 현재 운영 방식에 맞는 위치를
사용합니다. `general_settings.store_model_in_db: true`인 환경에서 YAML과 database에
동일한 `model_name`을 중복 등록하면 load balancing 대상이 될 수 있으므로 한 source에서
관리합니다.

다음 model deployment가 이미 생성되어 있어야 합니다.

| 모델 ID | 모델 버전 | 권장 LiteLLM alias |
| --- | --- | --- |
| `gpt-5.6-sol` | `2026-07-09` | `foundry-gpt-5.6-sol` |
| `gpt-5.6-terra` | `2026-07-09` | `foundry-gpt-5.6-terra` |
| `gpt-5.6-luna` | `2026-07-09` | `foundry-gpt-5.6-luna` |

세 모델은 Responses API와 Chat Completions API, reasoning, structured output, image
input, function calling을 지원합니다. Context window는 1,050,000 tokens, 입력 한도는
922,000 tokens, 최대 output은 128,000 tokens입니다. 입력, 출력과 reasoning token은
같은 context budget을 사용하므로 세 한도를 더한 용량이 보장되는 것은 아닙니다.

Foundry portal에서 다음 값을 확인합니다.

- Microsoft Foundry resource endpoint
- 각 모델의 실제 **Deployment name**
- LiteLLM host에 연결할 managed identity
- 해당 리전의 모델 가용성과 GPT-5.6 quota

Model ID와 deployment name은 다를 수 있습니다. LiteLLM의
`azure/responses/<deployment-name>`에는 model ID가 아니라 실제 deployment name을
사용합니다. Claude Code의 Anthropic 전용 `[1m]` suffix는 붙이지 않습니다.

## 2. LiteLLM host에 managed identity 연결

Azure VM, App Service, Container Apps처럼 managed identity endpoint를 제공하는 hosting
환경이 필요합니다. AKS의 Microsoft Entra Workload ID는 token 획득 방식이 다르므로 이
절차의 범위에 포함하지 않습니다.

### 2.1 Identity와 network 준비

LiteLLM host의 Azure portal **Identity** 화면에서 다음 중 하나를 활성화합니다.

- **System assigned**: 별도 client ID를 설정하지 않습니다.
- **User assigned**: identity를 host에 연결하고 `AZURE_CLIENT_ID`에 client ID를
  지정합니다.

Microsoft Foundry resource에 public network, IP 또는 VNet 제한이 있다면 LiteLLM
host가 허용된 network에 있어야 합니다. Private endpoint를 사용하면 resource hostname의
private DNS 해석과 outbound TCP 443 연결을 확인합니다.

### 2.2 Inference 역할 할당

GPT-5.6 deployment가 있는 Microsoft Foundry resource의 **Access control (IAM)**에서
LiteLLM host의 managed identity에 **Cognitive Services OpenAI User** 역할을
할당합니다. 역할은 deployment가 아니라 resource 범위에 할당합니다.
역할 전파에는 몇 분이 걸릴 수 있으므로 할당 직후 `401` 또는 `403`이 발생하면 잠시
기다린 뒤 다시 검증합니다.

### 2.3 환경변수 설정

| 변수 | 값 또는 확인 위치 |
| --- | --- |
| `FOUNDRY_GPT_API_BASE` | Resource의 **Keys and Endpoint**에 표시된 endpoint host |
| `FOUNDRY_GPT_API_VERSION` | `v1` |
| `FOUNDRY_GPT_AZURE_SCOPE` | `https://ai.azure.com/.default` |
| `AZURE_CLIENT_ID` | User-assigned identity의 client ID. System-assigned에서는 미설정 |

```dotenv
FOUNDRY_GPT_API_BASE=https://<resource-name>.openai.azure.com
FOUNDRY_GPT_API_VERSION=v1
FOUNDRY_GPT_AZURE_SCOPE=https://ai.azure.com/.default
```

Resource에 따라 `*.openai.azure.com` 또는 `*.services.ai.azure.com` endpoint가
표시될 수 있으므로 portal 값을 사용합니다. `FOUNDRY_GPT_API_BASE`에는
`/openai/v1`, `/responses` 또는 끝의 `/`를 붙이지 않습니다.

User-assigned identity를 사용할 때만 다음 값을 추가합니다.

```dotenv
AZURE_CLIENT_ID=<user-assigned-managed-identity-client-id>
```

`FOUNDRY_GPT_API_KEY`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`은 설정하지 않습니다.
System-assigned identity에서는 `AZURE_CLIENT_ID`도 설정하지 않습니다.

### 2.4 기존 Azure credential 충돌 확인

LiteLLM은 process의 `AZURE_OPENAI_API_KEY` 또는 `AZURE_API_KEY`가 있으면 managed
identity보다 API key를 먼저 사용합니다. 세 service principal 환경변수가 모두 있거나
`AZURE_CREDENTIAL`이 설정된 경우에도 다른 credential이 선택될 수 있습니다.

```bash
env | cut -d= -f1 | grep -E \
  '^(AZURE_OPENAI_API_KEY|AZURE_API_KEY|AZURE_CLIENT_SECRET|AZURE_TENANT_ID|AZURE_CREDENTIAL|AZURE_AD_TOKEN)$' \
  || true
```

Foundry에 managed identity만 사용하려면 위 전역 credential을 LiteLLM process에서
제거합니다. 기존 Azure 모델이 전역 API key에 의존한다면 해당 모델에 별도 이름의
환경변수를 명시적으로 연결합니다.

```yaml
  - model_name: existing-azure-model
    litellm_params:
      model: azure/<existing-deployment-name>
      api_base: os.environ/EXISTING_AZURE_API_BASE
      api_key: os.environ/EXISTING_AZURE_API_KEY
      api_version: os.environ/EXISTING_AZURE_API_VERSION
```

이 분리가 불가능하면 API key 기반 모델과 managed identity 기반 Foundry 모델을 서로
다른 LiteLLM instance에서 운영합니다.

### 2.5 Managed identity token 확인

아래 명령을 LiteLLM과 같은 container 또는 process 환경에서 실행합니다. Token 값은
출력하지 않습니다.

```bash
python - <<'PY'
import os
from datetime import datetime, timezone

from azure.identity import ManagedIdentityCredential

client_id = os.getenv("AZURE_CLIENT_ID")
credential = ManagedIdentityCredential(client_id=client_id)
token = credential.get_token(
    os.getenv("FOUNDRY_GPT_AZURE_SCOPE", "https://ai.azure.com/.default")
)
expires_at = datetime.fromtimestamp(token.expires_on, tz=timezone.utc)
print(f"managed identity token acquired; expires_at={expires_at.isoformat()}")
PY
```

LiteLLM Proxy의 표준 `proxy` 설치에는 `azure-identity`가 포함됩니다. 이 검증은 identity
endpoint만 확인하므로 Foundry RBAC는 4절의 API smoke test에서 별도로 확인합니다.

## 3. 기존 `model_list`에 Foundry 모델 추가

기존 모델을 유지한 채 다음 세 항목을 병합하고 placeholder를 실제 deployment name으로
바꿉니다. 기존 `litellm_settings`가 있다면
`enable_azure_ad_token_refresh: true`만 병합합니다.

```yaml
model_list:
  # 기존 모델은 그대로 유지합니다.

  - model_name: foundry-gpt-5.6-sol
    litellm_params:
      model: azure/responses/<sol-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
      azure_scope: os.environ/FOUNDRY_GPT_AZURE_SCOPE
    model_info:
      base_model: azure/gpt-5.6-sol

  - model_name: foundry-gpt-5.6-terra
    litellm_params:
      model: azure/responses/<terra-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
      azure_scope: os.environ/FOUNDRY_GPT_AZURE_SCOPE
    model_info:
      base_model: azure/gpt-5.6-terra

  - model_name: foundry-gpt-5.6-luna
    litellm_params:
      model: azure/responses/<luna-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
      azure_scope: os.environ/FOUNDRY_GPT_AZURE_SCOPE
    model_info:
      base_model: azure/gpt-5.6-luna

litellm_settings:
  enable_azure_ad_token_refresh: true
```

`azure/responses/<deployment-name>`은 LiteLLM의 `/v1/responses`와 `/v1/messages`
변환을 모두 Azure Responses API로 보냅니다. Chat Completions 경로용 alias가 별도로
필요하면 `azure/gpt5_series/<deployment-name>`을 추가할 수 있습니다.

System-assigned 방식에서 LiteLLM은 `DefaultAzureCredential`, user-assigned 방식에서는
`AZURE_CLIENT_ID`를 이용한 `ManagedIdentityCredential`을 선택합니다. 두 방식 모두
token을 자동 갱신합니다.

`AZURE_CLIENT_ID`와 `enable_azure_ad_token_refresh`는 LiteLLM process 전체에
적용됩니다. 기존 keyless `azure/...` 모델이 같은 identity를 사용해도 되는지와 각
모델의 `azure_scope`를 확인합니다. 서로 다른 identity가 필요하면 instance를 분리합니다.

## 4. Foundry route를 순서대로 검증

기존 운영 절차로 LiteLLM을 rolling restart한 뒤 URL과 virtual key를 설정합니다.

```bash
export LITELLM_BASE_URL="https://<litellm-host>"
export LITELLM_KEY="<litellm-virtual-key>"
```

먼저 Sol을 Responses API로 확인합니다.

```bash
curl -sS "$LITELLM_BASE_URL/v1/responses" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "content-type: application/json" \
  -d '{
    "model": "foundry-gpt-5.6-sol",
    "input": "Reply with exactly: FOUNDRY SOL OK"
  }'
```

Sol이 성공하면 Terra와 Luna를 각각 호출합니다.

```bash
for model in foundry-gpt-5.6-terra foundry-gpt-5.6-luna; do
  curl -sS "$LITELLM_BASE_URL/v1/responses" \
    -H "Authorization: Bearer $LITELLM_KEY" \
    -H "content-type: application/json" \
    -d "{
      \"model\": \"$model\",
      \"input\": \"Reply with exactly: $model OK\"
    }"
done
```

마지막으로 Claude Code가 사용하는 Anthropic Messages 변환 경로를 확인합니다.

```bash
curl -sS "$LITELLM_BASE_URL/v1/messages" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "foundry-gpt-5.6-sol",
    "max_tokens": 64,
    "messages": [
      {
        "role": "user",
        "content": "Reply with exactly: FOUNDRY VIA MESSAGES OK"
      }
    ]
  }'
```

`/v1/responses`는 성공하고 `/v1/messages`만 실패하면 LiteLLM의
Anthropic-to-Responses 변환 호환성을 먼저 확인합니다. LiteLLM 버전을 변경하기 전에
현재 stable 버전의 non-Anthropic 모델 가이드와 release note를 검토합니다.

## 5. Claude Code에서 Foundry 모델 노출

`~/.claude/settings.json`의 unrelated 설정은 유지하고 다음 값을 병합합니다. 프로젝트
범위가 필요하면 credential이 commit되지 않는 `.claude/settings.local.json`을
사용합니다. `ANTHROPIC_BASE_URL`에는 `/v1/messages`를 붙이지 않습니다.

```json
{
  "model": "foundry-gpt-5.6-sol",
  "env": {
    "ANTHROPIC_BASE_URL": "https://<litellm-host>",
    "ANTHROPIC_AUTH_TOKEN": "<litellm-virtual-key>",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

이 리포의 `scripts/configure_claude_code.py`는 Databricks workspace URL, credential과
`databricks-claude-*` 기본 모델을 다시 저장하므로 위 설정 후 실행하지 않습니다.
기존에 이 스크립트로 설정했다면 다음 기준으로 정리합니다.

- 같은 LiteLLM에 [Databricks alias](existing-litellm-databricks.md)도 등록되어 있고 virtual
  key가 접근할 수 있으면 기존 `ANTHROPIC_DEFAULT_*` picker 값은 유지할 수 있습니다.
- Foundry 모델만 제공하는 LiteLLM이면 기존 `databricks-claude-*`를 가리키는 최상위
  `model`, `ANTHROPIC_DEFAULT_*`, `ANTHROPIC_CUSTOM_MODEL_OPTION*` 값을 제거하고 위처럼
  `model`을 `foundry-gpt-5.6-sol`로 지정합니다.

Claude Code 2.1.129 이상은 LiteLLM의 `GET /v1/models`를 호출하고 virtual key가 접근할
수 있는 모델을 `/model` picker의 **From gateway**에 표시합니다. Alias가 보이지 않으면
virtual key에 `foundry-gpt-5.6-*` 모델 권한을 추가합니다.

```bash
for model in \
  foundry-gpt-5.6-sol \
  foundry-gpt-5.6-terra \
  foundry-gpt-5.6-luna; do
  claude --model "$model" \
    -p "Reply with exactly: $model CLAUDE CODE OK" \
    --output-format json
done
```

VS Code extension을 사용하면 VS Code 사용자 settings의
`claudeCode.environmentVariables`에도 같은 LiteLLM URL, virtual key, gateway discovery
값을 설정합니다. `~/.claude/settings.json`만으로는 extension의 로그인 확인에 값이
제때 전달되지 않을 수 있습니다.

Foundry GPT 모델은 LiteLLM이 Anthropic request와 response를 변환하는 non-Anthropic
backend입니다. Tool use, reasoning, image input처럼 실제 사용할 기능을 각각 검증한 뒤
사용자에게 공개합니다.

> **완료 기준:** `/status`의 Anthropic base URL이 조직의 LiteLLM URL이고,
> `/model`의 **From gateway**에 세 alias가 표시되며 세 Claude Code 테스트가 모두
> 성공합니다.

## 선택: 비용 추적

위 `base_model`은 Global Standard 가격 key입니다. US 또는 EU Data Zone deployment는
각각 `azure/us/gpt-5.6-*`, `azure/eu/gpt-5.6-*` key를 사용합니다. Resource 위치가
아니라 실제 deployment type을 기준으로 선택합니다.

LiteLLM이 local cost map만 사용한다면 GPT-5.6 metadata가 포함된 버전을 사용하거나
Admin UI의 **Reload Model Cost Map** 또는 기존 운영 절차의
`POST /reload/model_cost_map`으로 최신 map을 불러옵니다.

## 문제 해결

| 증상 | 확인할 항목 |
| --- | --- |
| LiteLLM `401` | virtual key, `Authorization` header, key의 만료와 상태 |
| `model not found` | 요청 alias, `model_name`, DB/YAML 적용 여부 |
| Foundry `404 DeploymentNotFound` | Model ID가 아니라 실제 deployment name을 사용했는지 |
| Foundry `401` 또는 `403` | managed identity, `Cognitive Services OpenAI User`, scope와 endpoint |
| `PublicNetworkAccessDisabled` 또는 network ACL `403` | Public access, private endpoint, VNet/IP allowlist, private DNS |
| managed identity 대신 API key가 사용됨 | 전역 `AZURE_OPENAI_API_KEY`, `AZURE_API_KEY`, model-level `api_key` |
| managed identity 대신 service principal이 사용됨 | `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_CREDENTIAL` |
| managed identity token 획득 실패 | `azure-identity`, host identity, `AZURE_CLIENT_ID`, identity endpoint |
| 기존 keyless Azure 모델 인증이 바뀜 | 전역 `AZURE_CLIENT_ID`, token refresh, identity와 scope |
| GPT-5.6 deployment 생성 실패 | 리전 가용성, subscription quota tier와 quota request |
| `/model`에 alias가 없음 | Gateway discovery, Claude Code 버전, virtual key 모델 권한 |
| 시작 시 Databricks model not found | repo script가 저장한 `model` 또는 `ANTHROPIC_DEFAULT_*` 값 |
| 비용이 unknown으로 표시됨 | `model_info.base_model`, cost map, pricing override |

## 공식 문서

- [LiteLLM GPT-5.6](https://docs.litellm.ai/blog/gpt_5_6)
- [LiteLLM Microsoft Foundry 연결용 Azure provider](https://docs.litellm.ai/docs/providers/azure)
- [LiteLLM Azure Responses API](https://docs.litellm.ai/docs/providers/azure/azure_responses)
- [LiteLLM custom pricing과 base model](https://docs.litellm.ai/docs/proxy/custom_pricing)
- [LiteLLM에서 non-Anthropic 모델 사용](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)
- [LiteLLM Messages-to-Responses mapping](https://docs.litellm.ai/docs/anthropic_unified/messages_to_responses_mapping)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Microsoft Foundry GPT-5.6 모델](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56)
- [Microsoft Foundry model endpoint와 deployment](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/endpoints)
- [Microsoft Foundry Responses API](https://learn.microsoft.com/azure/foundry/openai/how-to/responses)
- [Microsoft Foundry v1 API](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle)
- [Microsoft Foundry inference RBAC 역할](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/role-based-access-control)
- [Microsoft Foundry private link](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link)
- [Azure managed identity 개요](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)
