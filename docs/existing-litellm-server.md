# 기존 LiteLLM 서버에 Azure Databricks Claude 연결하기

이 가이드는 고객이 이미 운영 중인 LiteLLM Proxy 서버가 있고, 현재 Claude Code의
Azure Databricks 직접 연결을 LiteLLM 경유 방식으로 바꾸려는 경우에 사용합니다.
LiteLLM 설치, 데이터베이스, TLS, 로드 밸런서와 모니터링은 기존 구성을 그대로
사용합니다.

```text
Claude Code
  └─ https://<litellm-host>/v1/messages
      └─ LiteLLM model alias
          └─ https://<workspace-host>/serving-endpoints
              └─ databricks-claude-*
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

## 공식 문서

- [LiteLLM Databricks provider](https://docs.litellm.ai/docs/providers/databricks)
- [LiteLLM Claude Code quickstart](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [LiteLLM proxy configuration](https://docs.litellm.ai/docs/proxy/configs)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Azure Databricks OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)
