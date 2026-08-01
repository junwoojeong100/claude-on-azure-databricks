# 기존 LiteLLM 서버에 Azure Databricks와 Microsoft Foundry 모델 연결하기

이 가이드는 고객이 이미 운영 중인 LiteLLM Proxy 서버가 있고, 현재 Claude Code의
Azure Databricks 직접 연결을 LiteLLM 경유 방식으로 바꾸려는 경우에 사용합니다.
LiteLLM 설치, 데이터베이스, TLS, 로드 밸런서와 모니터링은 기존 구성을 그대로
사용합니다. Databricks Claude 연결을 먼저 완료한 뒤, 선택적으로 Microsoft Foundry의
GPT-5.6 Sol, Terra, Luna를 같은 LiteLLM 서버에 순서대로 추가할 수 있습니다.

```text
Claude Code
  └─ https://<litellm-host>/v1/messages
      └─ LiteLLM model alias
          ├─ Azure Databricks: databricks-claude-*
          └─ Microsoft Foundry: foundry-gpt-5.6-*
```

> 적용 전 현재 LiteLLM 버전에서
> [Claude Code 호환성](https://docs.litellm.ai/docs/claude_code_compatibility)을
> 확인하고, 기존 `config.yaml`, 환경변수와 데이터베이스를 백업하세요.

## 변경 사항 요약

| 위치 | 현재 직접 연결 | LiteLLM 경유 후 |
| --- | --- | --- |
| Claude Code `ANTHROPIC_BASE_URL` | Databricks `/serving-endpoints/anthropic` | LiteLLM 공개 URL |
| Claude Code credential | Databricks PAT/OAuth token | LiteLLM virtual key |
| Databricks credential | 사용자 PC에도 존재 | LiteLLM 서버에만 존재 |
| Claude Code 모델 이름 | `databricks-claude-*` | 같은 이름을 LiteLLM alias로 유지 |
| LiteLLM `model_list` | Databricks Claude 항목 없음 | `databricks/<model-id>` backend 추가 |
| Foundry GPT-5.6 | 등록되지 않음 | Databricks 완료 후 별도 alias로 추가 |

기존 alias를 그대로 사용하면 Claude Code의 기본 모델과 `/model` picker mapping은 변경할
필요가 없습니다. LiteLLM에 이미 등록된 다른 provider와 모델도 삭제하지 않습니다.

## 1. 현재 LiteLLM 설정 위치 확인

LiteLLM을 시작하는 명령에서 실제 설정 파일과 환경변수 주입 위치를 먼저 확인합니다.

```bash
ps -ef | grep '[l]itellm'
```

일반적으로 다음 중 하나에서 관리합니다.

- systemd: `ExecStart`의 `--config` 경로와 `EnvironmentFile`
- Docker Compose: `command`, `environment`, `env_file`, volume mount
- Kubernetes: Deployment의 args, Secret, ConfigMap
- LiteLLM Admin UI: 데이터베이스에 저장된 model과 server setting

`general_settings.store_model_in_db: true`를 사용하면 Admin UI나 API로 추가한 모델은
데이터베이스에도 존재합니다. 이 경우 조직의 기존 운영 방식에 맞춰 Admin UI/API로
Databricks 모델을 추가하세요. YAML 모델과 동일한 `model_name`을 데이터베이스에 또
추가하면 두 deployment가 load balancing 대상이 될 수 있으므로 중복 등록하지 않습니다.

## 2. LiteLLM 서버에 Databricks credential 추가

운영 환경은 Databricks service principal의 OAuth M2M을 권장합니다. LiteLLM process에
다음 환경변수를 주입합니다.

```dotenv
DATABRICKS_API_BASE=https://<workspace-host>/serving-endpoints
DATABRICKS_CLIENT_ID=<service-principal-application-id>
DATABRICKS_CLIENT_SECRET=<service-principal-secret>
```

빠른 검증에만 PAT를 사용한다면 client ID와 secret 대신 다음 값을 설정합니다.

```dotenv
DATABRICKS_API_BASE=https://<workspace-host>/serving-endpoints
DATABRICKS_API_KEY=<databricks-pat>
```

`DATABRICKS_API_BASE`에는 `/anthropic`이나 `/v1/messages`를 붙이지 않습니다. credential은
`config.yaml`, 컨테이너 이미지 또는 Git에 저장하지 말고 기존 Secret 관리 방식을
사용합니다.

Service principal에는 workspace 접근 권한과 모델 호출 권한이 필요합니다. Foundation
Model Unity Catalog 권한 기능을 사용하면 대상 `system.ai` 모델의 `EXECUTE`, custom
serving endpoint라면 endpoint의 `CAN QUERY`도 확인합니다.

## 3. 기존 `model_list`에 Databricks Claude 추가

현재 `config.yaml`의 기존 `model_list` 항목을 유지한 채 아래 항목을 병합합니다.
`model_name`은 Claude Code가 보내는 이름이고, `litellm_params.model`은 LiteLLM이
Databricks provider로 전달할 backend 이름입니다.

```yaml
model_list:
  # 기존 모델은 그대로 유지합니다.

  - model_name: databricks-claude-opus-5
    litellm_params:
      model: databricks/databricks-claude-opus-5
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-opus-4-8
    litellm_params:
      model: databricks/databricks-claude-opus-4-8
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-sonnet-5
    litellm_params:
      model: databricks/databricks-claude-sonnet-5
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-sonnet-4-6
    litellm_params:
      model: databricks/databricks-claude-sonnet-4-6
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-haiku-4-5
    litellm_params:
      model: databricks/databricks-claude-haiku-4-5
      api_base: os.environ/DATABRICKS_API_BASE

general_settings:
  # 기존 master_key 또는 database 설정을 유지합니다.
  master_key: os.environ/LITELLM_MASTER_KEY
```

OAuth M2M 환경변수를 사용하면 LiteLLM이 `DATABRICKS_CLIENT_ID`와
`DATABRICKS_CLIENT_SECRET`을 사용합니다. PAT 방식은 각 항목에 다음 줄을 추가하거나,
LiteLLM process의 `DATABRICKS_API_KEY` 자동 인식을 사용합니다.

```yaml
      api_key: os.environ/DATABRICKS_API_KEY
```

Workspace에서 호출할 수 없는 모델은 등록하지 않습니다. `[1m]` suffix도 LiteLLM
`model_name`에 넣지 않습니다. Claude Code가 `databricks-claude-opus-5[1m]`처럼
선택하면 `[1m]`을 제거한 모델 이름을 LiteLLM에 보내고 1M context beta header를
별도로 추가합니다.

기존 `general_settings`, `router_settings`, callback, budget, rate limit와 database
설정을 위 예시로 덮어쓰지 말고 필요한 항목만 병합합니다.

## 4. LiteLLM 재시작 전후 검증

먼저 기존 운영 절차로 설정 문법과 Secret 주입을 확인한 뒤, rolling restart나
maintenance 절차를 사용해 LiteLLM을 다시 시작합니다. 단일 인스턴스를 즉시 재시작하면
기존 사용자 요청이 중단될 수 있습니다.

재시작 후 health endpoint를 확인합니다.

```bash
curl -fsS "https://<litellm-host>/health"
```

그다음 LiteLLM virtual key로 Anthropic Messages endpoint를 직접 호출합니다.

```bash
export LITELLM_BASE_URL="https://<litellm-host>"
export LITELLM_KEY="<litellm-virtual-key>"

curl -sS "$LITELLM_BASE_URL/v1/messages" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "databricks-claude-opus-5",
    "max_tokens": 16,
    "messages": [
      {
        "role": "user",
        "content": "Reply with exactly: LITELLM OK"
      }
    ]
  }'
```

응답의 최상위 `type`이 `message`이면 LiteLLM 인증, alias와 Databricks backend가 모두
연결된 것입니다. 모델별 virtual key 권한을 사용한다면 해당 key에 위 alias를
허용했는지도 확인합니다.

## 5. Claude Code 설정에서 두 값만 교체

기존 `~/.claude/settings.json`에서 모델 picker 관련
`ANTHROPIC_DEFAULT_*` 값은 유지하고 다음 값만 바꿉니다.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<litellm-host>",
    "ANTHROPIC_AUTH_TOKEN": "<litellm-virtual-key>",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

- `ANTHROPIC_BASE_URL`에서 Databricks `/serving-endpoints/anthropic`을 제거하고 LiteLLM
  공개 URL을 사용합니다.
- `ANTHROPIC_AUTH_TOKEN`에는 Databricks token이 아니라 LiteLLM master key 또는 virtual
  key를 사용합니다. 사용자 단말에는 최소 권한의 virtual key를 권장합니다.
- Databricks와 LiteLLM 조합을 먼저 검증하는 동안
  `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`을 유지합니다.
- 기존 설정의 `permissions.deny`에 `WebSearch`가 있다면 그대로 유지합니다.

이 리포의 `scripts/configure_claude_code.py`는 Databricks 직접 연결용이므로 LiteLLM
전환 후 다시 실행하지 않습니다. 다시 실행하면 base URL과 credential이 Databricks
값으로 돌아갑니다.

정적 virtual key 대신 조직의 vault나 인증 시스템에서 key를 발급한다면
`ANTHROPIC_AUTH_TOKEN`을 저장하지 말고 Claude Code의 `apiKeyHelper`를 사용합니다.

## 6. Claude Code 최종 확인

Claude Code를 완전히 종료한 뒤 새 터미널에서 실행합니다.

```bash
claude --model "databricks-claude-opus-5[1m]" \
  -p "Reply with exactly: CLAUDE CODE LITELLM OK" \
  --output-format json
```

`is_error`가 `false`이고 `modelUsage`에 선택한 alias가 표시되어야 합니다. 대화형
세션의 `/status`에서는 다음 값을 확인합니다.

- `Anthropic base URL`: LiteLLM URL
- `Auth token`: `ANTHROPIC_AUTH_TOKEN` 또는 `apiKeyHelper`

VS Code extension도 사용한다면 VS Code 사용자 settings의
`claudeCode.environmentVariables`에 같은 LiteLLM URL과 key를 별도로 설정합니다.

## 7. 선택: Microsoft Foundry GPT-5.6 배포 확인

이 단계는 앞의 Databricks Claude 연결이 정상 동작한 뒤 진행합니다. 기존 Databricks
환경변수와 `model_list`는 변경하거나 삭제하지 않습니다.

> 공식 Microsoft Learn과 LiteLLM 문서 확인: 2026-08-01.

Microsoft Foundry에서 다음 Azure OpenAI model deployment가 이미 생성되어 있어야
합니다.

| 모델 ID | 현재 모델 버전 | 권장 LiteLLM alias |
| --- | --- | --- |
| `gpt-5.6-sol` | `2026-07-09` | `foundry-gpt-5.6-sol` |
| `gpt-5.6-terra` | `2026-07-09` | `foundry-gpt-5.6-terra` |
| `gpt-5.6-luna` | `2026-07-09` | `foundry-gpt-5.6-luna` |

세 모델은 Responses API와 Chat Completions API, reasoning, structured output, image input,
function calling을 지원합니다. 모델 context window는 1,050,000 tokens이지만 Claude
Code의 Anthropic 전용 `[1m]` suffix는 붙이지 않습니다.

Foundry portal에서 다음 값을 확인합니다.

- Azure OpenAI resource endpoint
- 각 모델의 실제 deployment name
- Azure OpenAI v1 API 사용 가능 여부
- API key 또는 Microsoft Entra identity
- 해당 리전의 모델 가용성과 GPT-5.6 quota

모델 ID와 deployment name은 다를 수 있습니다. 예를 들어 모델 ID가
`gpt-5.6-sol`이어도 deployment name을 `prod-sol`로 만들었다면 LiteLLM backend에는
`prod-sol`을 사용해야 합니다. 가능하면 deployment name에 `gpt-5.6`을 포함해 LiteLLM의
모델 family 자동 인식을 단순화하세요. 비용과 context metadata는 아래 `base_model`로
별도 지정합니다.

## 8. LiteLLM 서버에 Foundry credential 추가

Foundry backend 호출에는 인증이 필요하지만 **API key가 반드시 필요한 것은 아닙니다**.
API key, service principal, managed identity 중 하나를 선택합니다. 세 deployment가 같은
Foundry resource에 있으면 endpoint와 인증 정보 하나를 세 모델이 공유하므로 모델별 key를
만들지 않습니다.

### 변수값 확인 위치

| 변수 또는 placeholder | 값 | 확인 위치 |
| --- | --- | --- |
| `FOUNDRY_GPT_API_BASE` | Azure OpenAI resource endpoint host | Foundry portal의 resource **Keys and Endpoint**, 또는 Azure portal의 해당 Foundry resource **Keys and Endpoint** |
| `FOUNDRY_GPT_API_KEY` | Resource의 Key 1 또는 Key 2 | 같은 **Keys and Endpoint** 화면. API key 방식에서만 사용 |
| `FOUNDRY_GPT_API_VERSION` | `v1` | Portal에서 복사하는 secret이 아니라 이 가이드에서 사용하는 LiteLLM Azure v1 route 선택값 |
| `<sol-deployment-name>` 등 | 각 deployment의 **Deployment name** | Foundry portal의 **Models + endpoints** > **Deployments**. Model ID가 아니라 deployment name 사용 |
| `AZURE_TENANT_ID` | Directory (tenant) ID | Microsoft Entra admin center의 **Entra ID** > **Overview** |
| `AZURE_CLIENT_ID` | Application (client) ID | Service principal은 **App registrations** > 해당 앱 > **Overview**. User-assigned managed identity는 해당 identity의 **Overview** |
| `AZURE_CLIENT_SECRET` | Client secret의 **Value** | **App registrations** > 해당 앱 > **Certificates & secrets**. Secret ID가 아니며 service principal 방식에서만 사용 |
| `FOUNDRY_GPT_AZURE_SCOPE` | `https://ai.azure.com/.default` | Azure OpenAI v1 API의 고정 Entra scope |

`FOUNDRY_GPT_API_BASE`에는 `/openai/v1`, `/chat/completions`, `/responses`를 붙이지
않습니다. 리소스에 따라 `*.openai.azure.com` 또는 `*.services.ai.azure.com` host가
표시될 수 있으므로 portal 값을 사용합니다. 끝의 `/` 유무는 현재 LiteLLM URL helper가
정규화합니다. `api_version: v1`은 LiteLLM이 resource endpoint 뒤에 `/openai/v1/`
경로를 선택하도록 하는 값입니다.

### 선택 A: API key

가장 간단한 smoke test 방식입니다. 기존 Secret 관리 위치에 다음 값을 추가합니다.

```dotenv
FOUNDRY_GPT_API_BASE=https://<resource-name>.openai.azure.com
FOUNDRY_GPT_API_KEY=<foundry-resource-api-key>
FOUNDRY_GPT_API_VERSION=v1
```

Key 1과 Key 2 중 하나만 사용합니다. 두 key는 rotation을 위한 resource-level
credential이며 Sol, Terra, Luna가 같은 resource에 배포됐다면 같은 key를 공유합니다.

### 선택 B: Service principal

Azure 밖에서 실행되는 LiteLLM처럼 managed identity를 사용할 수 없는 운영 환경에
적합합니다. 다음 Secret을 준비합니다.

```dotenv
FOUNDRY_GPT_API_BASE=https://<resource-name>.openai.azure.com
FOUNDRY_GPT_API_VERSION=v1
AZURE_TENANT_ID=<tenant-id>
AZURE_CLIENT_ID=<service-principal-client-id>
AZURE_CLIENT_SECRET=<service-principal-client-secret>
FOUNDRY_GPT_AZURE_SCOPE=https://ai.azure.com/.default
```

Service principal에 Azure portal의 해당 Foundry/Azure OpenAI resource
**Access control (IAM)**에서 **Cognitive Services OpenAI User** 역할을 할당합니다.
`AZURE_CLIENT_SECRET`에는 secret을 생성할 때 한 번 표시되는 **Value**를 저장하며
configuration 파일이나 source control에 직접 기록하지 않습니다.

### 선택 C: Managed identity

Azure VM, App Service, Container Apps 또는 AKS처럼 managed identity를 지원하는 환경의
운영 LiteLLM에는 이 방식을 우선 사용합니다. LiteLLM host에 system-assigned 또는
user-assigned managed identity를 연결하고, 해당 identity에 Foundry/Azure OpenAI
resource 범위의 **Cognitive Services OpenAI User** 역할을 할당합니다.

```dotenv
FOUNDRY_GPT_API_BASE=https://<resource-name>.openai.azure.com
FOUNDRY_GPT_API_VERSION=v1
FOUNDRY_GPT_AZURE_SCOPE=https://ai.azure.com/.default
```

System-assigned identity는 별도 client ID나 secret이 없습니다. User-assigned identity를
선택해야 한다면 host 환경에 그 identity의 client ID를 `AZURE_CLIENT_ID`로 설정합니다.
`AZURE_CLIENT_SECRET`과 `FOUNDRY_GPT_API_KEY`는 설정하지 않습니다.

Microsoft Entra 방식의 scope는 Azure OpenAI v1 API 예시와 맞습니다. 날짜 기반 legacy
API를 사용하는 기존 LiteLLM 구성은
`https://cognitiveservices.azure.com/.default`를 사용할 수 있으므로, v1과 legacy
설정의 scope를 섞지 않습니다.

API key와 service principal secret을 동시에 `config.yaml`에 직접 입력하지 않습니다.
먼저 API key로 연결을 검증한 뒤 Entra 인증으로 전환한다면 한 번에 한 인증 방식만
활성화하고 다시 smoke test합니다.

## 9. 기존 `model_list`에 Foundry 모델 추가

앞의 Databricks 항목 아래에 세 deployment를 추가합니다. 아래
`<sol-deployment-name>`, `<terra-deployment-name>`, `<luna-deployment-name>`은 Foundry
portal에 표시되는 실제 deployment name으로 바꿉니다.

다음은 **API key 방식**의 전체 예시입니다. `api_key`는 모델별 key가 아니라 같은
resource key 환경변수를 세 항목이 함께 참조합니다.

```yaml
model_list:
  # 기존 Databricks와 다른 provider 모델은 그대로 유지합니다.

  - model_name: foundry-gpt-5.6-sol
    litellm_params:
      model: azure/responses/<sol-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_key: os.environ/FOUNDRY_GPT_API_KEY
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
    model_info:
      base_model: azure/gpt-5.6-sol

  - model_name: foundry-gpt-5.6-terra
    litellm_params:
      model: azure/responses/<terra-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_key: os.environ/FOUNDRY_GPT_API_KEY
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
    model_info:
      base_model: azure/gpt-5.6-terra

  - model_name: foundry-gpt-5.6-luna
    litellm_params:
      model: azure/responses/<luna-deployment-name>
      api_base: os.environ/FOUNDRY_GPT_API_BASE
      api_key: os.environ/FOUNDRY_GPT_API_KEY
      api_version: os.environ/FOUNDRY_GPT_API_VERSION
    model_info:
      base_model: azure/gpt-5.6-luna
```

`azure/responses/<deployment-name>`은 LiteLLM의 `/v1/responses`와 Claude Code가
사용하는 `/v1/messages` 변환을 모두 Azure Responses API로 보냅니다. Chat Completions
전용 alias가 별도로 필요하다면 `azure/gpt5_series/<deployment-name>`을 추가할 수
있지만, 그 형식을 위 Claude Code alias 대신 사용하지 않습니다.

Service principal 인증을 사용하는 경우 각 모델의 `api_key` 줄을 제거하고 다음 필드를
같은 `litellm_params` 아래에 추가합니다. 나머지 model entry는 API key 예시와
동일합니다.

```yaml
      tenant_id: os.environ/AZURE_TENANT_ID
      client_id: os.environ/AZURE_CLIENT_ID
      client_secret: os.environ/AZURE_CLIENT_SECRET
      azure_scope: os.environ/FOUNDRY_GPT_AZURE_SCOPE
```

Managed identity 인증을 사용하는 경우 각 모델에서 `api_key`, `tenant_id`, `client_id`,
`client_secret`을 모두 생략하고 `azure_scope`만 유지합니다. 기존 최상위
`litellm_settings`가 있다면 새로 만들지 말고 아래 값을 병합합니다.

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

  # Terra와 Luna도 같은 형태로 추가합니다.

litellm_settings:
  enable_azure_ad_token_refresh: true
```

이 설정에서 LiteLLM은 `DefaultAzureCredential` 경로로 token을 자동 갱신합니다.
운영 host에는 의도한 managed identity만 사용할 수 있도록 불필요한 Azure CLI login과
service principal 환경변수를 두지 않습니다.

`base_model`은 custom deployment name과 실제 GPT-5.6 tier를 연결해 cost와 context
metadata를 정확히 선택합니다. 위 예시는 Global Standard 가격 key입니다. US 또는 EU
지역 가격을 적용해야 한다면 LiteLLM cost map의 `azure/us/gpt-5.6-*` 또는
`azure/eu/gpt-5.6-*` key를 사용합니다. 별도 계약 가격은 `model_info`의 token별 pricing
필드로 override합니다.

LiteLLM이 로컬 cost map만 사용한다면 GPT-5.6 metadata가 포함된 버전을 사용하거나 최신
cost map을 다시 불러옵니다. Admin UI의 **Reload Model Cost Map** 또는 기존 운영 절차의
`POST /reload/model_cost_map`은 LiteLLM 1.76.0 이상에서 사용할 수 있습니다.

## 10. Foundry route를 순서대로 검증

기존 운영 절차로 LiteLLM을 rolling restart한 뒤 먼저 Sol을 Responses API로
확인합니다. GPT-5.6의 reasoning state와 output item을 사용하는 애플리케이션에는
`/v1/responses`가 기본 검증 경로입니다.

```bash
curl -sS "$LITELLM_BASE_URL/v1/responses" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "content-type: application/json" \
  -d '{
    "model": "foundry-gpt-5.6-sol",
    "input": "Reply with exactly: FOUNDRY SOL OK"
  }'
```

Sol이 성공하면 같은 방식으로 Terra와 Luna를 각각 호출합니다.

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

그다음 Claude Code가 사용하는 Anthropic Messages 변환 경로를 Sol로 확인합니다.
LiteLLM은 `/v1/messages` 요청을 Foundry의 Responses API 형식으로 변환합니다.

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

`/v1/responses`는 성공하고 `/v1/messages`만 실패하면 Foundry deployment보다 LiteLLM의
Anthropic-to-Responses 변환 호환성을 먼저 확인합니다. LiteLLM 버전을 변경하기 전에는
현재 stable 버전의 non-Anthropic 모델 가이드와 release note를 검토하세요. LiteLLM의
Claude Code compatibility matrix는 Azure Foundry의 Claude tier를 자동 검증하지만
GPT-5.6 Sol, Terra, Luna를 직접 인증하는 표는 아니므로 실제 기능별 smoke test를
대체하지 않습니다.

## 11. Claude Code에서 Foundry 모델 노출

기존 LiteLLM URL과 virtual key는 그대로 사용하고 gateway model discovery만 추가합니다.

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<litellm-host>",
    "ANTHROPIC_AUTH_TOKEN": "<litellm-virtual-key>",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

Claude Code 2.1.129 이상은 시작할 때 LiteLLM의 `GET /v1/models`를 호출하고, virtual
key가 접근할 수 있는 모델을 `/model` picker의 **From gateway** 항목에 표시합니다.
Foundry alias가 보이지 않으면 virtual key에 `foundry-gpt-5.6-*` 모델 권한을 추가합니다.

각 모델을 직접 확인할 수도 있습니다.

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

Foundry GPT 모델은 LiteLLM이 Anthropic request와 response를 변환해 제공하는
non-Anthropic backend입니다. Claude 전용 beta 기능이 모두 동일하게 동작한다고
가정하지 말고, tool use, reasoning, image input처럼 실제로 사용할 기능을 각각
검증한 뒤 사용자에게 공개합니다.

## 문제 해결

| 증상 | 확인할 항목 |
| --- | --- |
| LiteLLM `401` | virtual key, `Authorization` header, key의 만료와 상태 |
| Databricks backend `401` | LiteLLM 서버의 M2M/PAT 환경변수, workspace host |
| `model not found` | 요청 alias와 `model_name`의 정확한 일치, DB/YAML 적용 여부 |
| `403 ... rate limit of 0` | Databricks 모델·리전, cross-Geo, 권한, 계정 용량 |
| beta 관련 `400` | Claude Code의 `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` |
| 기존 모델이 사라짐 | `model_list` 전체 덮어쓰기 여부, DB 설정 source 확인 |
| 설정을 바꿔도 반영되지 않음 | `store_model_in_db`, Admin UI 값, 실제 `--config` 경로 |
| `[1m]` 모델을 찾지 못함 | LiteLLM alias에서 `[1m]` 제거, Claude Code 최신 버전 |
| Foundry `404 DeploymentNotFound` | model ID가 아니라 실제 deployment name을 사용했는지 |
| Foundry `401` 또는 `403` | API key, Entra identity, resource endpoint와 RBAC |
| GPT-5.6 deployment 생성 실패 | 리전 가용성, subscription quota tier와 quota request |
| `/model`에 Foundry alias가 없음 | gateway discovery, Claude Code 버전, virtual key 모델 권한 |
| 비용이 unknown으로 표시됨 | `model_info.base_model`, cost map 갱신, pricing override |

## 공식 문서

- [LiteLLM Databricks provider](https://docs.litellm.ai/docs/providers/databricks)
- [LiteLLM Claude Code quickstart](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [LiteLLM proxy configuration](https://docs.litellm.ai/docs/proxy/configs)
- [LiteLLM GPT-5.6](https://docs.litellm.ai/blog/gpt_5_6)
- [LiteLLM Azure OpenAI provider](https://docs.litellm.ai/docs/providers/azure)
- [LiteLLM Azure Responses API](https://docs.litellm.ai/docs/providers/azure/azure_responses)
- [LiteLLM custom pricing과 base model](https://docs.litellm.ai/docs/proxy/custom_pricing)
- [LiteLLM에서 non-Anthropic 모델 사용](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models)
- [LiteLLM Messages-to-Responses mapping](https://docs.litellm.ai/docs/anthropic_unified/messages_to_responses_mapping)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Azure Databricks OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)
- [Microsoft Foundry GPT-5.6 모델](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure#gpt-56)
- [Microsoft Foundry model endpoint와 deployment](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/endpoints)
- [Azure OpenAI Responses API](https://learn.microsoft.com/azure/foundry/openai/how-to/responses)
- [Azure OpenAI v1 API](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle)
- [Azure OpenAI RBAC 역할](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/role-based-access-control)
- [Microsoft Entra app registration](https://learn.microsoft.com/entra/identity-platform/quickstart-register-app)
- [Microsoft Entra client credential 관리](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials)
- [Azure managed identity 개요](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)
