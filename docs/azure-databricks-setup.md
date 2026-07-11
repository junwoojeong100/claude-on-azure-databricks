# Azure Databricks 환경 설정

이 가이드의 목표는 Claude 모델을 호출할 수 있는 Azure Databricks workspace와 로컬
`.env`를 준비하는 것입니다.

완료하면 다음 두 API를 테스트할 수 있습니다.

```text
OpenAI compatible:  /serving-endpoints/chat/completions
Anthropic native:   /serving-endpoints/anthropic/v1/messages
```

## 준비 사항

| 항목 | 요구사항 |
| --- | --- |
| Azure 권한 | 리소스 생성 시 Contributor 또는 동등한 권한 |
| Azure CLI | 로그인 완료, Databricks 확장 설치 |
| 로컬 도구 | Git, `curl`, Python 3.10 이상 |
| 모델 | 대상 리전에서 사용 가능한 Databricks-hosted Claude |
| 인증 | 로컬 실습은 PAT, 운영은 서비스 주체 OAuth M2M 권장 |

모델 ID와 리전 가용성은 다음 공식 문서에서 확인합니다.

- [지원 모델](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [리전별 Foundation Model 가용성](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/foundation-model-overview)

## 방법 A: 자동 설정

macOS, Linux, WSL에서 빈 구독 또는 새 리소스 그룹으로 시작할 때 가장 빠른 경로입니다.

### 1. 로컬 환경 준비

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else "Python 3.10+ required")'
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

### 2. Azure 로그인

```bash
az extension add --name databricks --upgrade
az login

# 여러 구독이 있으면 대상 구독 선택
az account set --subscription "<name-or-id>"
```

### 3. 설정 실행

```bash
scripts/setup_databricks_claude.sh
```

기본값:

| 변수 | 기본값 | 역할 |
| --- | --- | --- |
| `RG` | `rg-databricks-claude` | 리소스 그룹 |
| `LOCATION` | `eastus2` | Azure 리전 |
| `WORKSPACE` | `ws-databricks-claude` | Databricks workspace |
| `SKU` | `premium` | Workspace SKU |
| `DATABRICKS_SERVING_ENDPOINT` | `databricks-claude-opus-4-8` | 기본 Claude 모델 |
| `RUN_AGENT` | `1` | 마지막에 Agent Framework 샘플 실행 |

예:

```bash
RG=my-rg LOCATION=koreacentral WORKSPACE=my-ws \
  scripts/setup_databricks_claude.sh

# API까지만 검증
RUN_AGENT=0 scripts/setup_databricks_claude.sh
```

스크립트는 다음 작업을 수행합니다.

1. 리소스 그룹과 Premium Databricks workspace 생성 또는 재사용
2. Azure 로그인으로 Databricks PAT 생성 또는 기존 유효 PAT 재사용
3. 프로젝트 루트에 권한이 제한된 `.env` 작성
4. Serving endpoint 목록 확인
5. OpenAI 호환 API와 네이티브 Anthropic API smoke test
6. 선택적으로 `src/agent_sample.py` 실행

같은 workspace에서 다시 실행하면 유효한 `.env` PAT를 재사용합니다. 명시적으로 새
PAT가 필요할 때만 다음을 사용합니다.

```bash
ROTATE_PAT=1 scripts/setup_databricks_claude.sh
```

새 PAT가 정상 동작하는지 확인한 뒤 사용하지 않는 이전 PAT는 workspace 설정에서
폐기하세요.

## 방법 B: 기존 workspace 사용

이미 Azure Databricks가 있다면 리소스를 새로 만들 필요가 없습니다.

### 1. 필요한 값 확인

1. Workspace URL: `https://<workspace>.azuredatabricks.net`
2. Serving → Endpoints에서 사용할 Claude 모델 ID
3. 해당 모델을 호출할 수 있는 token

일반 serving endpoint ACL에서는 `CAN QUERY`가 필요합니다. Foundation Model Unity
Catalog 권한 기능을 사용한다면 대상 `system.ai` 모델의 `EXECUTE`도 필요합니다.

> Azure 구독 Owner/Contributor 또는 Databricks workspace admin은 Databricks account
> admin과 다른 역할입니다. 기본 모델 호출에는 account admin이 필요하지 않지만,
> account-level Preview와 일부 시스템 테이블 관리에는 별도 account admin 권한이
> 필요할 수 있습니다.

### 2. Python 환경과 `.env` 준비

macOS/Linux/WSL:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
cp .env.example .env
chmod 600 .env
```

Windows PowerShell:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
icacls .env /inheritance:r /grant:r "${env:USERNAME}:(M)"
```

`.env`:

```dotenv
DATABRICKS_HOST=https://<workspace>.azuredatabricks.net
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<databricks-token>
```

선택적으로 Claude Code 모델 후보를 지정할 수 있습니다.

```dotenv
DATABRICKS_FAST_ENDPOINT=databricks-claude-haiku-4-5
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5"
```

기본 Claude Code 후보는 Opus/Sonnet/Haiku입니다. Fable 5를 추가하기 전에는
[30일 보존과 일부 사람 검토 정책](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models#claude-fable-5)을
먼저 확인하세요.

## 연결 확인

### Agent Framework

OpenAI 호환 경로를 확인합니다.

macOS/Linux/WSL:

```bash
.venv/bin/python src/agent_sample.py
```

Windows PowerShell:

```powershell
.\.venv\Scripts\python.exe src\agent_sample.py
```

### 네이티브 Anthropic API

macOS/Linux/WSL:

```bash
set -a
. ./.env
set +a

printf 'header = "Authorization: Bearer %s"\n' "$DATABRICKS_TOKEN" |
  curl --config - -sS \
    "$DATABRICKS_HOST/serving-endpoints/anthropic/v1/messages" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
      \"model\": \"$DATABRICKS_SERVING_ENDPOINT\",
      \"max_tokens\": 16,
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: OK\"}]
    }"
```

정상 응답에는 `"type": "message"`가 포함됩니다.

Windows PowerShell:

```powershell
$Config = @{}
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $Config[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
}

$Headers = @{
    Authorization       = "Bearer $($Config['DATABRICKS_TOKEN'])"
    'anthropic-version' = '2023-06-01'
}
$Body = @{
    model      = $Config['DATABRICKS_SERVING_ENDPOINT']
    max_tokens = 16
    messages   = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
} | ConvertTo-Json -Depth 5

$HostUrl = $Config['DATABRICKS_HOST'].TrimEnd('/')
(Invoke-RestMethod `
    "$HostUrl/serving-endpoints/anthropic/v1/messages" `
    -Method Post -Headers $Headers -ContentType 'application/json' -Body $Body).type
```

기대값은 `message`입니다.

## 자주 발생하는 문제

| 증상 | 확인할 항목 |
| --- | --- |
| `az databricks` 명령이 없음 | `az extension add --name databricks --upgrade` |
| PAT 생성 실패 | Workspace 접근 권한과 PAT 허용 정책 |
| `401` | Workspace URL, token 만료, 다른 workspace의 token인지 확인 |
| `403 ... rate limit of 0` | 모델·리전, cross-Geo 정책, endpoint/사용자 rate limit, `CAN QUERY`/`EXECUTE`, 계정 용량 |
| 모델을 찾을 수 없음 | 현재 workspace에서 실제 제공되는 endpoint ID 확인 |
| OpenAI 경로는 성공하고 Claude만 실패 | 공통 인증은 정상일 가능성이 높으므로 Claude 모델 가용성과 용량을 우선 확인 |

일반 사용량 초과는 보통 `429`입니다. `403`과 `rate limit of 0` 조합은 단순 재시도보다
모델 제공 조건과 계정 설정을 먼저 확인해야 합니다.

## 정리

기본 자동 설정 리소스가 더 이상 필요하지 않으면:

```bash
az group delete -n rg-databricks-claude --yes --no-wait
```

다음 단계: [Microsoft Agent Framework 실습](agent-framework.md)
