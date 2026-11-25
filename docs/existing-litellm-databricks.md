# 기존 LiteLLM을 통해 Claude Code를 Azure Databricks에 연결하기

이 가이드는 고객이 이미 운영 중인 LiteLLM Proxy 서버가 있고, Claude Code의 Azure
Databricks 직접 연결을 LiteLLM 경유 방식으로 바꾸려는 경우에 사용합니다. LiteLLM
설치, 데이터베이스, TLS, 로드 밸런서와 모니터링은 기존 구성을 그대로 사용합니다.
이 가이드는 [Databricks 직접 연결](claude-code-databricks.md)의 대안입니다.
기존 LiteLLM을 사용할 경우 직접 연결 설정을 먼저 저장하지 않습니다. Workspace URL,
credential, 호출 가능한 모델 ID가 확실하지 않을 때만 직접 연결 가이드의
[API 검증 절](claude-code-databricks.md#2-databricks-api부터-검증)을 수행하세요.
LiteLLM이 아직 없다면 이 문서 대신 [LiteLLM 설치부터 연결하는 실습 가이드](https://junwoojeong100.github.io/claude-on-azure-databricks/databricks-litellm.html#s1)를
1단계부터 따라 하세요.

```text
Claude Code
  └─ https://<litellm-host>/v1/messages
      └─ LiteLLM model alias
          └─ Azure Databricks: databricks-claude-*
```

> 적용 전 현재 LiteLLM 버전에서
> [Claude Code 호환성](https://docs.litellm.ai/docs/claude_code_compatibility)을
> 확인하고, 기존 `config.yaml`, 환경변수와 데이터베이스를 백업하세요.

작업은 두 역할로 나뉩니다. LiteLLM 관리자는 1~4절(서버에 Databricks 추가)을 마친 뒤
[사용자에게 전달](#사용자에게-전달)하고, Claude Code 사용자는 5~6절(값 두 개 교체)을
수행합니다. 서버에 Databricks 모델이 이미 등록되어 있다면(4절의 `/v1/models`로 확인)
사용자는 5절부터 시작합니다.

## 변경 사항 요약

| 위치 | 현재 직접 연결 | LiteLLM 경유 후 |
| --- | --- | --- |
| Claude Code `ANTHROPIC_BASE_URL` | Databricks `/serving-endpoints/anthropic` | LiteLLM 공개 URL |
| Claude Code credential | Databricks PAT/OAuth token | LiteLLM virtual key |
| Databricks credential | 사용자 PC에도 존재 | LiteLLM 서버에만 존재 |
| Claude Code 모델 이름 | `databricks-claude-*` | 같은 이름을 LiteLLM alias로 유지 |
| LiteLLM `model_list` | Databricks Claude 항목 없음 | `databricks/<model-id>` backend 추가 |

기존 alias를 그대로 사용하면 Claude Code의 기본 모델과 `/model` picker mapping은
변경할 필요가 없습니다. LiteLLM에 이미 등록된 다른 provider와 모델도 삭제하지 않습니다.

## 1. 현재 LiteLLM 설정 위치 확인

이 리포에는 `config.yaml`이 없습니다. 이 문서의 `config.yaml`은 고객의 기존 LiteLLM
서버가 실제로 읽는 설정 파일을 뜻합니다. Admin UI와 database로 설정을 관리한다면
이 절차를 위해 새 `config.yaml`을 만들지 말고 기존 Admin UI/API에서 같은 모델
항목을 추가합니다.

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
Databricks 모델을 추가하세요(3절의 [API로 추가](#데이터베이스로-관리하는-서버-api로-추가)).
YAML 모델과 동일한 `model_name`을 데이터베이스에 또 추가하면 두 deployment가 load
balancing 대상이 될 수 있으므로 중복 등록하지 않습니다.

모델이 YAML과 데이터베이스 중 어디서 관리되는지는 관리자 key로 확인할 수 있습니다.
`db`는 데이터베이스, `config`는 YAML이 관리하는 모델입니다.

```bash
export LITELLM_BASE_URL="https://<litellm-host>"
export LITELLM_ADMIN_KEY="<litellm-admin-key>"

curl -s "$LITELLM_BASE_URL/model/info" -H "Authorization: Bearer $LITELLM_ADMIN_KEY" \
  | python3 -c 'import sys,json; [print(m["model_name"], "db" if m["model_info"].get("db_model") else "config") for m in json.load(sys.stdin)["data"]]'
```

## 2. LiteLLM 서버에 Databricks credential 추가

다음 두 방식 중 **하나만** 선택해 LiteLLM process에 환경변수로 주입합니다.

| 용도 | 인증 방식 | 설정할 환경변수 |
| --- | --- | --- |
| 운영 환경 | OAuth M2M 권장 | `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET` |
| 빠른 검증 | PAT | `DATABRICKS_API_KEY` |

### 방법 A: OAuth M2M

Databricks service principal의 application ID와 OAuth secret을 사용합니다.

```dotenv
DATABRICKS_API_BASE=https://<workspace-host>/serving-endpoints
DATABRICKS_CLIENT_ID=<service-principal-application-id>
DATABRICKS_CLIENT_SECRET=<service-principal-secret>
```

LiteLLM은 이 값으로 workspace OAuth token을 발급받아 Databricks를 호출합니다.

### 방법 B: PAT

빠른 검증에만 PAT를 사용합니다. 이 방식을 선택했다면 LiteLLM process에 기존
`DATABRICKS_CLIENT_ID`와 `DATABRICKS_CLIENT_SECRET`이 남아 있지 않은지 확인합니다.

```dotenv
DATABRICKS_API_BASE=https://<workspace-host>/serving-endpoints
DATABRICKS_API_KEY=<databricks-pat>
```

LiteLLM의 인증 선택 순서는 **OAuth M2M → PAT → Databricks SDK 기본 인증**입니다.
따라서 M2M 환경변수와 PAT를 함께 넣으면 M2M이 사용됩니다. Route-optimized endpoint는
OAuth가 필요하므로 PAT 대신 방법 A를 사용합니다.

두 방식 모두 `DATABRICKS_API_BASE`에는 `/anthropic`, `/v1/messages` 또는
`/chat/completions`를 붙이지 않습니다. LiteLLM이 backend 요청 경로를 추가합니다.
Credential은 `config.yaml`, 컨테이너 이미지 또는 Git에 저장하지 말고 기존 Secret
관리 방식을 사용합니다.

Service principal에는 workspace 접근 권한과 호출 대상에 대한 권한이 필요합니다.

- Pay-per-token foundation model: Foundation Model Unity Catalog 권한 기능으로
  기본 접근을 제한했다면 `system.ai` schema 또는 대상 모델의 `EXECUTE`
- Custom 또는 provisioned serving endpoint: endpoint의 `CAN QUERY`

LiteLLM 서버가 사설망이나 방화벽 안에 있다면 Databricks workspace
(`*.azuredatabricks.net`)로 나가는 HTTPS(443)가 열려 있어야 합니다. Workspace에 IP
access list나 Private Link 전용 설정이 있다면 LiteLLM 서버가 그 경로로 접근할 수
있어야 합니다.

## 3. 기존 `model_list`에 Databricks Claude 추가

현재 `config.yaml`의 기존 `model_list` 항목을 유지한 채 아래 항목을 병합합니다.
`model_name`은 Claude Code가 보내는 이름이고, `litellm_params.model`은 LiteLLM이
Databricks provider로 전달할 backend 이름입니다. 인증정보는 2절의 process
환경변수에서 읽으므로 M2M과 PAT 모두 아래 YAML을 그대로 사용합니다.

```yaml
model_list:
  # 기존 모델은 그대로 유지합니다.

  - model_name: databricks-claude-opus-5-5
    litellm_params:
      model: databricks/databricks-claude-opus-5-5
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-opus-5
    litellm_params:
      model: databricks/databricks-claude-opus-5
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-sonnet-5-5
    litellm_params:
      model: databricks/databricks-claude-sonnet-5-5
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-sonnet-5
    litellm_params:
      model: databricks/databricks-claude-sonnet-5
      api_base: os.environ/DATABRICKS_API_BASE

  - model_name: databricks-claude-haiku-5-5
    litellm_params:
      model: databricks/databricks-claude-haiku-5-5
      api_base: os.environ/DATABRICKS_API_BASE
```

YAML에 `api_key`를 추가할 필요가 없습니다. 방법 A에서는 LiteLLM이
`DATABRICKS_CLIENT_ID`와 `DATABRICKS_CLIENT_SECRET`을 사용하고, 방법 B에서는
`DATABRICKS_API_KEY`를 사용합니다. 이 process의 전역 Databricks 환경변수는 등록된
모든 `databricks/...` 모델에 적용되므로 서로 다른 workspace credential을 섞지
않습니다.

Workspace에서 호출할 수 없는 모델은 등록하지 않습니다. `[1m]` suffix도 LiteLLM
`model_name`에 넣지 않습니다. 이 리포의 구성은 `[1m]` 없이 모델 이름만 보내고, 예전
구성처럼 `databricks-claude-sonnet-4-6[1m]`을 선택해도 Claude Code가 `[1m]`을 제거한
모델 이름을 LiteLLM에 보내고 1M context beta header를 별도로 추가합니다.

기존 `general_settings`, `router_settings`, callback, budget, rate limit와 database
설정은 변경하지 않고 `model_list`의 필요한 항목만 병합합니다.

### 데이터베이스로 관리하는 서버: API로 추가

`store_model_in_db: true`인 서버는 YAML 대신 관리 API로 같은 항목을 추가합니다. 모델은
데이터베이스에 저장되고 재시작 없이 새 요청부터 적용됩니다. 단, 2절의 환경변수를 새로
넣었다면 먼저 LiteLLM을 한 번 재시작해 process에 반영해야 합니다(4절 첫 단락). 이
API는 `store_model_in_db`가 켜져 있어야 동작하며, 요청에는 `os.environ/` 참조만 넣으므로
token이 포함되지 않습니다.

```bash
export LITELLM_BASE_URL="https://<litellm-host>"
export LITELLM_ADMIN_KEY="<litellm-admin-key>"

for model in databricks-claude-opus-5-5 databricks-claude-opus-5 \
             databricks-claude-sonnet-5-5 databricks-claude-sonnet-5 \
             databricks-claude-haiku-5-5; do
  curl -sS -o /dev/null -w "$model -> HTTP %{http_code}\n" -X POST "$LITELLM_BASE_URL/model/new" \
    -H "Authorization: Bearer $LITELLM_ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model_name\":\"$model\",\"litellm_params\":{\"model\":\"databricks/$model\",\"api_base\":\"os.environ/DATABRICKS_API_BASE\"}}"
done
```

- 서버에 `general_settings.enforce_rpm_tpm_on_model_add: true`가 있으면 `rpm`과 `tpm`이 없는
  요청은 `400`으로 거부됩니다. `litellm_params`에 `"rpm": 100, "tpm": 100000`처럼 한도를
  함께 넣습니다.
- Admin UI의 **Models + Endpoints → Add Model**에서도 Provider **Databricks**로 추가할 수
  있지만, 이 폼은 API Key가 필수 입력입니다. 서버 환경변수로 인증하는 이 가이드의
  방식에는 위 API가 더 간단합니다.
- YAML에 정의된 모델은 API나 UI에서 수정하거나 삭제할 수 없습니다. 한 모델 이름은 YAML과
  데이터베이스 중 한 곳에서만 관리하세요.

## 4. LiteLLM 재시작 전후 검증

먼저 기존 운영 절차로 설정 문법과 Secret 주입을 확인한 뒤, rolling restart나
maintenance 절차를 사용해 LiteLLM을 다시 시작합니다. 단일 인스턴스를 즉시 재시작하면
기존 사용자 요청이 중단될 수 있습니다. 3절의 API로 모델을 추가하는 데이터베이스
방식도 2절의 환경변수를 새로 넣었다면 이 재시작이 한 번 필요합니다. 실행 중인
process에는 환경변수를 추가할 수 없기 때문이며, 이후의 모델 추가·변경은 재시작 없이
적용됩니다.

재시작 후 LiteLLM key를 준비하고, 실제 모델 호출을 수행하는 authenticated health
endpoint를 확인합니다. `/health`는 모델마다 소량의 token을 사용할 수 있습니다.

```bash
export LITELLM_BASE_URL="https://<litellm-host>"
export LITELLM_KEY="<litellm-virtual-key>"

curl -fsS "$LITELLM_BASE_URL/health" \
  -H "Authorization: Bearer $LITELLM_KEY"
```

Process와 database readiness만 확인하는 load balancer probe에는 인증이 필요 없는
`/health/liveliness`와 `/health/readiness`를 사용합니다. 그다음 등록된 모델 목록에
`databricks-claude-*`가 보이는지 확인합니다. 이 목록에는 해당 key에 허용된 모델만
표시됩니다.

```bash
curl -s "$LITELLM_BASE_URL/v1/models" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  | python3 -c 'import sys,json; [print(m["id"]) for m in json.load(sys.stdin)["data"]]'
```

보이지 않으면 [사용자 key에 새 alias 허용](#사용자-key에-새-alias-허용)을 확인합니다.
그다음 LiteLLM virtual key로 Anthropic Messages endpoint를 직접 호출합니다.

```bash
curl -sS "$LITELLM_BASE_URL/v1/messages" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "databricks-claude-opus-5-5",
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
허용했는지도 확인합니다(아래 [사용자 key에 새 alias 허용](#사용자-key에-새-alias-허용)).

LiteLLM을 거치면 `databricks-claude-opus-5`는 `thinking` 블록을 먼저 만들기 때문에
`max_tokens`가 너무 작으면(예: 16) `stop_reason`이 `max_tokens`로 끝나고 `text`가 비어
보일 수 있습니다. 기본 모델인 Opus 5.5와 Sonnet 5.5, Sonnet 5, Haiku 5.5는 16에서도
바로 `text`가 반환됩니다. 모델을 바꿔 가며 확인할 때는 64 이상을 사용하세요.

### 사용자 key에 새 alias 허용

Key나 team에 허용 모델(`models`)이 지정되어 있으면 허용 목록에 없는 alias는
`/v1/models`에 나타나지 않고, 호출하면 `403 permission_error`로 거부됩니다.

- `models`가 비어 있는(모든 모델 허용) key는 추가 작업이 없습니다.
- Access group을 사용한다면 새 모델을 기존 그룹에 넣습니다. 그 그룹을 쓰는 key는 수정
  없이 바로 반영됩니다. YAML 항목(또는 3절 API 요청 본문)에 `litellm_params`와 같은
  수준으로 `model_info`를 추가합니다.

  ```yaml
  model_info:
    access_groups: ["<group>"]
  ```

- Key에 모델을 직접 나열했다면 `POST /key/update`의 `models`에 새 alias를 추가합니다.
  `models`는 전체 목록을 교체하므로 기존 모델도 함께 보내야 합니다.

### 사용자에게 전달

4절의 검증이 끝나면 관리자 작업은 끝입니다. 사용자에게 다음 세 가지를 전달하고,
사용자는 5절부터 이어갑니다.

- LiteLLM URL: `https://<litellm-host>` (`/v1/messages`는 붙이지 않음)
- 사용자별 virtual key (Databricks token이 아님)
- 사용할 alias: `databricks-claude-*` (모델 picker 설정은 그대로)

## 5. Claude Code 설정에서 두 값만 교체

기존 `~/.claude/settings.json`에서 모델 picker 관련 `ANTHROPIC_DEFAULT_*` 값은
유지하고 다음 두 값만 바꿉니다. 값은 관리자에게 전달받은 LiteLLM URL과 key입니다.

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

조직이 managed settings, 기기 관리 또는 `apiKeyHelper`로 gateway 주소와 credential을
이미 배포했다면 이 절을 건너뜁니다. `claude`를 실행해 `/status`의 `Anthropic base URL`이
LiteLLM 주소인지만 확인합니다.

## 6. Claude Code 최종 확인

Claude Code를 완전히 종료한 뒤 새 터미널에서 실행합니다.

```bash
claude --model "databricks-claude-opus-5-5" \
  -p "Reply with exactly: CLAUDE CODE LITELLM OK" \
  --output-format json
```

`is_error`가 `false`이고 `modelUsage`에 선택한 alias가 표시되어야 합니다. 대화형
세션의 `/status`에서는 다음 값을 확인합니다.

- `Anthropic base URL`: LiteLLM URL
- `Auth token`: `ANTHROPIC_AUTH_TOKEN` 또는 `apiKeyHelper`

VS Code extension도 사용한다면 VS Code 사용자 settings의
`claudeCode.environmentVariables`에 같은 LiteLLM URL과 key를 별도로 설정합니다.

> **완료 기준:** `/status`의 Anthropic base URL이 조직의 LiteLLM URL이고,
> `claude --model "databricks-claude-opus-5-5"` 테스트가 성공합니다.

## 되돌리기

연동을 철회할 때는 이 가이드가 추가한 것만 되돌립니다. 기존 서버의 다른 모델, key,
team 설정과 컨테이너·볼륨은 건드리지 않습니다.

- YAML 서버(관리자): 3절에서 병합한 `databricks-claude-*` 항목을 `model_list`에서 지우고,
  이 연동에만 쓴 `DATABRICKS_*` 환경변수를 제거한 뒤 rolling restart합니다.
- DB 서버(관리자): 아래 명령으로 추가한 모델을 삭제합니다. 재시작은 필요 없습니다.
  Admin UI의 모델 상세 화면에서 **Delete Model**로도 지울 수 있습니다. 이 연동에만 쓴
  환경변수는 따로 제거합니다.
- 사용자: 5절의 두 값을 이전 값(직접 연결 값이나 이전 gateway 값)으로 되돌립니다.

```bash
export LITELLM_BASE_URL="https://<litellm-host>"
export LITELLM_ADMIN_KEY="<litellm-admin-key>"

# DB 서버: 추가한 databricks-claude-* 항목만 삭제 (YAML 모델은 API로 삭제할 수 없음)
curl -s "$LITELLM_BASE_URL/model/info" -H "Authorization: Bearer $LITELLM_ADMIN_KEY" \
  | python3 -c 'import sys,json; [print(m["model_info"]["id"]) for m in json.load(sys.stdin)["data"] if m["model_name"].startswith("databricks-claude-") and m["model_info"].get("db_model")]' \
  | while read -r id; do
      curl -sS -o /dev/null -w "$id -> HTTP %{http_code}\n" -X POST "$LITELLM_BASE_URL/model/delete" \
        -H "Authorization: Bearer $LITELLM_ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$id\"}"
    done
```

## 문제 해결

| 증상 | 확인할 항목 |
| --- | --- |
| LiteLLM `401` | virtual key, `Authorization` header, key의 만료와 상태 |
| Databricks backend `401` | LiteLLM 서버의 M2M/PAT 환경변수, workspace host |
| `model not found` | 요청 alias와 `model_name`의 정확한 일치, DB/YAML 적용 여부 |
| `403 permission_error` 또는 `/v1/models`에 alias가 없음 | key·team의 허용 모델(`models`), access group에 `databricks-claude-*` 추가 |
| 모델 추가 API가 `400 rpm and tpm must be set…` | 서버의 `enforce_rpm_tpm_on_model_add`, `litellm_params`에 `rpm`·`tpm` 지정 |
| Databricks backend 연결 오류·timeout | LiteLLM 서버의 outbound HTTPS(443), 방화벽·Private Link, workspace IP access list |
| `403 ... rate limit of 0` | Databricks 모델·리전, cross-Geo, 권한, 계정 용량 |
| beta 관련 `400` | Claude Code의 `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` |
| 기존 모델이 사라짐 | `model_list` 전체 덮어쓰기 여부, DB 설정 source 확인 |
| 설정을 바꿔도 반영되지 않음 | `store_model_in_db`, Admin UI 값, 실제 `--config` 경로 |
| `[1m]`이 붙은 모델을 찾지 못함 | LiteLLM `model_name`에 `[1m]`을 넣지 않았는지, Claude Code 버전(5.5 계열은 2.1.293 이상) |

## 공식 문서

- [LiteLLM Databricks provider](https://docs.litellm.ai/docs/providers/databricks)
- [LiteLLM Claude Code quickstart](https://docs.litellm.ai/docs/tutorials/claude_responses_api)
- [LiteLLM proxy configuration](https://docs.litellm.ai/docs/proxy/configs)
- [LiteLLM model management](https://docs.litellm.ai/docs/proxy/model_management)
- [LiteLLM model access](https://docs.litellm.ai/docs/proxy/model_access)와
  [model access groups](https://docs.litellm.ai/docs/proxy/model_access_groups)
- [Claude Code LLM gateway 연결](https://code.claude.com/docs/en/llm-gateway-connect)
- [Azure Databricks OAuth M2M](https://learn.microsoft.com/azure/databricks/dev-tools/auth/oauth-m2m)
- [Foundation model Unity Catalog 권한](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/model-uc-permissions)
- [Model serving endpoint 권한 관리](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/manage-serving-endpoints#permissions)
