# Azure Databricks Claude Agent Sample

[Microsoft Agent Framework](https://learn.microsoft.com/agent-framework/) (Python)
기반으로 **Azure Databricks Model Serving**에 배포된 **Anthropic Claude Opus 4.8**
모델을 사용하는 최소 샘플입니다.

## 이 리포로 할 수 있는 것

1. **Python 에이전트 샘플** — Microsoft Agent Framework로 Databricks의 Claude Opus 4.8을
  호출하는 최소 예제(`src/agent_sample.py`). 아래 **§0~§4**로 바로 실습할 수 있습니다.
2. **Claude Code 백엔드 연결** — 터미널 코딩 CLI [Claude Code](https://code.claude.com/)의
  LLM을 Databricks의 **네이티브 Anthropic Messages API**에 직접 연결합니다. LiteLLM,
  로컬 포트, 백그라운드 프록시는 필요하지 않습니다.
  → [docs/claude-code-databricks.md](docs/claude-code-databricks.md)

Python 샘플은 Databricks의 표준 OpenAI 호환 경로
`/serving-endpoints/chat/completions`를 사용합니다. Agent Framework가 다중 턴 이력에
추가하는 선택적 `name` 필드만 Databricks Claude가 거부하므로, httpx 훅은 이 필드만
제거합니다. URL 변환이나 LiteLLM은 사용하지 않습니다.

> 📌 **이 README 하나로 전체 실습(설치·설정·실행·문제 해결·관리자 권한)이 완결됩니다.**
> Databricks vs Microsoft Foundry 심화 비교와 모니터링 리소스·비용 상세는 참고용 문서
> [docs/databricks-vs-foundry-models.md](docs/databricks-vs-foundry-models.md)에 있습니다.

> 💻 **[Claude Code](https://code.claude.com/)(Anthropic 터미널 코딩 CLI)의 LLM을 이 Databricks
> Claude 엔드포인트로 설정**하려면 — 네이티브 `/serving-endpoints/anthropic` 연결,
> 안전한 token helper, `~/.claude/settings.json` 구성·검증까지 —
> **[docs/claude-code-databricks.md](docs/claude-code-databricks.md)** 가이드를 참고하세요.
> 원클릭 스크립트 [`scripts/setup_claude_code_databricks.sh`](scripts/setup_claude_code_databricks.sh)로
> 직접 연결 설정이 자동화됩니다.
> 요건·주의사항 요약(동료·고객·파트너 공유용)은
> [docs/claude-code-databricks-checklist.md](docs/claude-code-databricks-checklist.md)를 참고하세요.

## 기존 Claude Code를 Databricks Claude로 전환 (한 명령)

> ✅ **이미 Claude Code가 설치돼 있고 `.env`에 자신의 Databricks 접속 정보가 있다면,
> 아래 설치기 한 번으로 전환됩니다.**

```bash
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
scripts/setup_claude_code_databricks.sh
```

Windows PowerShell:

```powershell
Remove-Item Env:ANTHROPIC_AUTH_TOKEN, Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
powershell -ExecutionPolicy Bypass -File scripts\setup_claude_code_databricks.ps1
```

### 실행 전 준비

1. [Claude Code](https://code.claude.com/)가 설치돼 있어야 합니다.
2. 리포를 clone하고 `.env.example`을 `.env`로 복사합니다.
3. `.env`에 고객/파트너 자신의 값을 입력합니다.

```dotenv
DATABRICKS_HOST=https://<workspace>.azuredatabricks.net
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<대상 모델에 CAN QUERY 권한이 있는 PAT>
```

macOS/Linux 설치기는 `curl`과 Python 3도 사용합니다. Claude 모델이 해당 Databricks
계정·리전에서 활성화돼 있어야 합니다.

### 설치기가 자동으로 하는 일

- 네이티브 `/serving-endpoints/anthropic/v1/messages` 호출 확인
- 기존 `~/.claude/settings.json` 백업 후 Databricks 직접 URL과 모델 프리셋 병합
- PAT를 설정 JSON에 넣지 않고 권한이 제한된 `apiKeyHelper` 파일에 저장
- 기존 LiteLLM launchd/systemd/Scheduled Task 중지
- Claude Code를 실제 실행해 `DIRECT OK` 종단 간 확인

기존 Claude Code 설정의 다른 항목은 보존됩니다. 전환 후에는 로컬 포트나 LiteLLM
프로세스가 필요하지 않습니다.

### 직접 연결 확인 (macOS/Linux)

```bash
jq -r '.env.ANTHROPIC_BASE_URL' ~/.claude/settings.json
# 기대값: https://<workspace>.azuredatabricks.net/serving-endpoints/anthropic

lsof -nP -iTCP:4000 -sTCP:LISTEN
# 기대값: 출력 없음

claude --model databricks-claude-opus-4-8 \
  -p "Reply with exactly: DIRECT OK" --output-format json
```

더 자세한 모델 전환, Windows 결과물, OAuth 및 문제 해결은
[Claude Code 직접 연결 가이드](docs/claude-code-databricks.md)를 참고하세요.

> 🚀 **처음이신가요?** 가장 쉬운 길은 **[§0 원클릭 스크립트](#0-원클릭-자동-설정-선택)** 입니다 —
> Azure에 로그인만 되어 있으면 리소스 그룹·워크스페이스·PAT·`.env` 생성부터 검증까지 자동으로
> 해줍니다. 각 단계를 직접 이해하며 하고 싶으면 **§1~§4**(사전 준비 → 설치 → 환경 변수 → 실행)를
> 순서대로 따르세요.

## 0. 원클릭 자동 설정 (선택)

리소스 그룹 생성부터 워크스페이스·PAT·`.env`·OpenAI 호환 API·네이티브 Anthropic
API 검증과 샘플 실행까지 자동화하는 스크립트를 제공합니다.

> **필요한 것:** [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
> Python 3.10 이상(3.12 권장), git, 그리고 리소스를 만들 수 있는 **Azure 구독**
> (Owner 또는 Contributor 권한). 처음이면 위 순서대로 아래 4단계를 그대로 복사·실행하세요.

```bash
# 1) 리포 클론 (이미 했다면 생략)
git clone https://github.com/junwoojeong100/azure-databricks-claude-agent-sample.git
cd azure-databricks-claude-agent-sample

# 2) 파이썬 가상환경 + 의존성 설치
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt

# 3) Azure 로그인 (브라우저 인증 창이 열립니다)
az login

# 4) 실행 — RG·워크스페이스·PAT·.env 생성 + 엔드포인트 검증 + 샘플 실행까지 자동
scripts/setup_databricks_claude.sh
# 기본값: RG=rg-databricks-claude · LOCATION=eastus2 · WORKSPACE=ws-databricks-claude
# 변경 예: RG=my-rg LOCATION=koreacentral WORKSPACE=my-ws scripts/setup_databricks_claude.sh
```

스크립트는 대상 엔드포인트(`databricks-claude-opus-4-8`) 호출을 테스트하고, 만약
`rate limit of 0`(403)으로 막히면 Anthropic이 이 테넌트/계정에 아직 엔타이틀되지 않은
것이므로([§5 문제 해결](#5-문제-해결-troubleshooting) 참고), Databricks 자체 호스팅 모델로
파이프라인이 정상 동작함을 대신 검증합니다.

> **비용 주의:** 기본 설정은 Premium Databricks 워크스페이스와 pay-per-token 모델을
> 사용합니다. 실습이 끝난 뒤 리소스 그룹 전체가 불필요하면
> `az group delete -n rg-databricks-claude --yes --no-wait`로 정리하세요.

## 1. 사전 준비

1. **Azure 구독 + Databricks 워크스페이스**(권장 SKU `premium`). Claude Opus 4.8 서빙
   엔드포인트(`databricks-claude-opus-4-8`)는 워크스페이스에 **기본 배포**돼 있습니다
   (Serving → Endpoints에서 확인). Claude는 Llama·GPT-OSS와 같은 **Databricks-hosted
   Foundation Model**(pay-per-token)입니다.
   - ⚠️ 단, Anthropic Claude는 **계정/지역별 서빙 용량 할당** 대상이라, 할당이 없는
     계정(= Entra ID 테넌트)에서는 호출이 `rate limit of 0`으로 막힙니다 →
     [§5 문제 해결](#5-문제-해결-troubleshooting) 참고.
2. **인증 정보** — 대상 엔드포인트에 **CAN QUERY** 권한이 필요합니다.
   운영 환경은 서비스 주체 **OAuth M2M**을 권장하며, 이 최소 샘플과 자동 설정은
   개발 편의를 위해
   [Databricks Personal Access Token](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat)을
   사용합니다. 워크스페이스 → Settings → Developer → Access tokens → Manage →
   Generate new token.
   (`§0` 자동 스크립트는 Azure 로그인으로 PAT를 자동 발급합니다.)
3. **Python 3.10 이상** (이 저장소는 3.12로 검증).

## 2. 설치

```bash
git clone https://github.com/junwoojeong100/azure-databricks-claude-agent-sample.git
cd azure-databricks-claude-agent-sample

python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

> `source .venv/bin/activate` 대신 `.venv/bin/python`을 직접 호출해도 됩니다.

## 3. 환경 변수 설정

`.env.example`을 복사해 `.env`로 만든 뒤 값을 채웁니다.

```bash
cp .env.example .env
```

| 변수 | 설명 | 예시 |
| --- | --- | --- |
| `DATABRICKS_HOST` | 워크스페이스 URL (스킴 포함, 끝 슬래시 없음) | `https://adb-1234567890.16.azuredatabricks.net` |
| `DATABRICKS_SERVING_ENDPOINT` | Claude Opus 4.8가 배포된 서빙 엔드포인트 이름 | `databricks-claude-opus-4-8` |
| `DATABRICKS_TOKEN` | Databricks PAT (`dapi...`) | `dapiXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX` |

Python 샘플은 다음 OpenAI 호환 URL에 `DATABRICKS_SERVING_ENDPOINT`를 `model`로
전달합니다:

```
{DATABRICKS_HOST}/serving-endpoints/chat/completions
```

Claude Code는 별도의 네이티브 Anthropic URL을 사용합니다:

```text
{DATABRICKS_HOST}/serving-endpoints/anthropic/v1/messages
```

## 4. 실행

```bash
.venv/bin/python src/agent_sample.py
```

스크립트 시작 시 `python-dotenv`가 프로젝트 루트의 `.env`를 자동으로 로드합니다.
별도로 `source .env`를 할 필요가 없습니다. 셸 환경 변수가 이미 설정돼 있다면
그 값이 우선합니다.

실행 흐름:

1. 시작과 동시에 한국어 **샘플 질문 3개**(`SAMPLE_QUESTIONS`)가 자동으로 큐에서
   순차 실행됩니다 — 사용자가 입력하지 않아도 곧바로 응답을 확인할 수 있습니다.
   각 샘플 턴은 프롬프트 라인 끝에 `(sample)` 라벨로 표시됩니다.
2. 모델이 첫 토큰을 보내기 전까지 같은 줄에서 브레일 스피너
   (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ 응답 대기 중…`)가 회전합니다. 첫 토큰이 도착하면 스피너가
   사라지고 응답이 스트리밍됩니다.
3. 매 턴마다 사용 토큰이 출력됩니다.
4. 샘플 큐가 비면 자동으로 사용자 입력(stdin) 모드로 전환됩니다. 빈 줄 또는
   Ctrl-D로 종료하면 누적 합계가 출력됩니다.

샘플 질문 목록(스크립트 상단 `SAMPLE_QUESTIONS`에서 자유롭게 수정 가능):

1. Azure Databricks Model Serving이 무엇인지 한 문단으로 설명해줘.
2. Microsoft Agent Framework와 Microsoft Foundry Agent Service의 차이를 비교해줘.
3. 이 샘플처럼 Databricks의 Claude 모델을 호출할 때 주의할 점 3가지를 알려줘.

출력 예시:

```
Databricks agent (databricks-claude-opus-4-8) — 대화를 시작합니다.
종료하려면 빈 줄을 입력하거나 Ctrl-D를 누르세요.
먼저 샘플 질문 3개를 자동으로 실행합니다.

[User] Azure Databricks Model Serving이 무엇인지 한 문단으로 설명해줘.  (sample)
⠹ 응답 대기 중…
[Agent] Azure Databricks Model Serving은 …
[Tokens] this turn: input=1458 output=421 total=1879
         | cumulative (1 turns): input=1458 output=421 total=1879

... (샘플 2, 3 자동 실행) ...

[User]                          ← 여기서부터 직접 입력
============================================================
세션 요약 — 3턴, 총 input=8203, output=1287, total=9490 tokens
```

> 토큰 카운트는 Databricks/Anthropic이 반환하는 `usage` 필드를 그대로 사용합니다.
> 캐시(cache_read / cache_creation) 토큰이 있을 경우 `total`이 단순히
> `input + output`이 아닐 수 있습니다.

## 5. 문제 해결 (Troubleshooting)

### `403 PERMISSION_DENIED: ... Databricks-set rate limit of 0` (Claude 호출 시)

먼저 사실 정리: Anthropic Claude는 Azure Databricks에서 **"Databricks-hosted" Foundation
Model**입니다(BYO 키를 쓰는 external 모델이 아님 — 릴리스 노트가 "Databricks-hosted model"로
명시). Llama·GPT-OSS와 동일한 OpenAI 호환 Foundation Model API를 사용하며, Claude는
`/serving-endpoints/anthropic/v1/messages` 네이티브 API도 제공합니다.
`system.ai` 카탈로그·DBU 과금·동일한 pay-per-token 한도(**200,000 ITPM**)를 따릅니다.
정상 한도 초과 시 반환은 **429**입니다.

따라서 `403 ... rate limit of 0`은 **정상 rate-limit이 아니라**, 이 계정에 대해 Databricks가
Claude 서빙 한도를 **0으로 막아 둔 상태**입니다. 공식 리전 표는 Claude를
*"supported based on GPU availability"* 로 표기합니다 — 즉 **Anthropic(라이선스 파트너)
모델은 계정별 서빙 용량 활성화 대상**이라, 완전 오픈 모델(Llama 등)과 달리 활성화되지 않은
계정에서는 이렇게 막힙니다. 같은 Entra 테넌트(= 같은 Databricks 계정)면 리전·워크스페이스를
바꿔도 동일합니다.

> **경험적 확인:** 이 값은 **새로 생성한 Databricks 계정에서 기본 0**으로 관찰됩니다 —
> 서로 다른 테넌트 2곳(관리형 구독 + 개인 Visual Studio Enterprise 구독), koreacentral·eastus2
> (네이티브 리전 포함)에서 **동일하게 Claude만 403, Llama 등 오픈 모델은 200**으로 재현됐습니다.
> 즉 리전·거버넌스 문제가 아니라 **계정 단위 Anthropic 활성화** 문제입니다.

**1) 계정 레벨 게이트인지 확인** — Databricks 자체 오픈 모델은 되는데 Claude만 막히면 위 상황입니다:

```bash
set -a; . ./.env; set +a          # DATABRICKS_HOST / DATABRICKS_TOKEN 로드
for EP in databricks-meta-llama-3-3-70b-instruct "$DATABRICKS_SERVING_ENDPOINT"; do
  printf '%s -> ' "$EP"
  printf 'header = "Authorization: Bearer %s"\n' "$DATABRICKS_TOKEN" |
  curl --config - -sS -o /dev/null -w '%{http_code}\n' -X POST \
    "$DATABRICKS_HOST/serving-endpoints/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$EP\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}"
done
# 오픈 모델 200 + Claude 403  →  계정에 Anthropic 서빙 용량이 할당되지 않은 상태
```

**2) 해결** — PAT·워크스페이스 권한·partner-powered·cross-Geo 등 **고객 설정으로는 바뀌지
않습니다**(모두 켜도 0). 공식 문서 안내대로:

- **Anthropic 용량이 이미 할당된 Entra 테넌트/구독**에서 실행하거나,
- **Azure Databricks account team에 문의**해 계정의 Anthropic 서빙 용량 활성화를 요청하세요
  (새로 생성한 Databricks 계정은 Anthropic pay-per-token이 기본 비활성(0)이며, 이는 관리형·개인
  구독 모두에서 재현됩니다).

**3) 비 EU/US 리전(예: `koreacentral`) 추가 조건** — Claude는 "EU/US" 모델이라 비EU/US
워크스페이스는 **cross-Geo 데이터 처리**도 켜져 있어야 합니다: account console → **Workspaces →
워크스페이스 → Security and compliance → "Enforce data processing within workspace Geography
for Designated Services" Off**. (단, 위 용량 할당과 별개 — 할당이 0이면 cross-Geo를 켜도 0입니다.)

### 관리자 권한이 필요한 작업

Azure Contributor/Owner는 워크스페이스를 만들고 처음 로그인해 **workspace admin**
권한을 얻을 수 있지만, **account admin**(메타스토어·시스템 테이블·계정 설정)은 별도입니다. 최초
account admin은 **Entra ID Global Administrator**가 [account console](https://accounts.azuredatabricks.net)에
로그인해 부트스트랩합니다. **3단계 권한 모델·부트스트랩·권한 매트릭스·자가 진단**은
[§7 관리자 권한 모델](#7-관리자-권한-모델) 참고.

### 샘플이 자동 처리하는 항목

- Agent Framework가 대화 이력의 assistant 메시지에 추가하는 `name` 필드는 Databricks
  Claude가 허용하지 않으므로, 최소 httpx 훅에서 이 필드만 **자동 제거**합니다
  (`src/agent_sample.py`).

## 6. 운영 모니터링 (Databricks)

서빙 엔드포인트에서 **Enable usage tracking**을 켜면
`system.serving.endpoint_usage`에 토큰 사용량이 수집됩니다. 별도의 Unity AI Gateway
Beta를 활성화한 계정은 `system.ai_gateway.usage`와 빌트인 대시보드도 사용할 수 있습니다.

| 위치 | 용도 |
| --- | --- |
| Databricks UI → Serving → 엔드포인트 상세 페이지 | (Custom / Provisioned Throughput 엔드포인트만) 인프라 헬스 메트릭 차트 |
| Databricks UI → Serving → AI Gateway → **Create / View Dashboard** | 토큰/요청/지연시간/사용자별 빌트인 대시보드 (account admin이 생성, 백엔드에 SQL Warehouse 사용) |
| `system.serving.endpoint_usage` / `system.ai_gateway.usage` (AI Gateway Beta) | 사용자/엔드포인트/시간 단위 집계, 비용 분석 (usage tracking 및 해당 Preview/권한 필요) |
| Inference Tables (엔드포인트 설정에서 활성화) | 모든 요청/응답 + 토큰을 Delta 테이블로 저장 |

예시 SQL:

```sql
SELECT
  date_trunc('hour', request_time) AS hour,
  endpoint_name,
  SUM(input_token_count)  AS input_tokens,
  SUM(output_token_count) AS output_tokens,
  COUNT(*)                AS requests
FROM system.serving.endpoint_usage
WHERE endpoint_name = 'databricks-claude-opus-4-8'
  AND request_time >= current_date() - INTERVAL 7 DAYS
GROUP BY 1, 2
ORDER BY 1 DESC;
```

> 모니터링을 위해 추가로 활성화/생성해야 하는 리소스(SQL Warehouse, Inference Tables,
> 시스템 스키마)와 비용 상세는 참고 문서
> [docs/databricks-vs-foundry-models.md](docs/databricks-vs-foundry-models.md) §11 참고.

## 7. 관리자 권한 모델

Databricks 운영 작업의 상당수는 **어느 관리자 역할이 있느냐**로 가능 여부가 갈립니다
(Workspace / Account / Metastore). 참고로 이 샘플의 `rate limit of 0`은 권한 문제가
아니라 계정 엔타이틀먼트 문제입니다 → [§5 문제 해결](#5-문제-해결-troubleshooting).

### 7.1 세 가지 레벨

| 레벨 | 스코프 | 부여 방법 | 대표 권한 |
| --- | --- | --- | --- |
| **Workspace admin** | 단일 Databricks workspace | Account admin이 만든 워크스페이스에서는 생성자가 자동 부여. 아직 역할이 없다면 Azure 구독 Owner/Contributor가 워크스페이스에 로그인해 획득할 수도 있음. 이후 UI/API로 위임 | 워크스페이스 내 사용자/그룹·권한·클러스터·서빙 엔드포인트·잡 관리, PAT 발급, 노트북 권한 |
| **Account admin** | Databricks **account** 전체 (테넌트 단위, account console = `accounts.azuredatabricks.net`) | **자동 부여되지 않음**. 최초 1회는 **Microsoft Entra ID Global Administrator**가 account console에 처음 로그인하여 부트스트랩. 이후 기존 account admin이 UI/API로 위임 | 계정 콘솔의 워크스페이스·메타스토어·시스템 테이블·Preview·계정 사용자/그룹·청구 설정 관리 |
| **Metastore admin** | Unity Catalog metastore 1개 (보통 region 1개) | 메타스토어 생성 시 지정 (account admin이 생성). 기본은 그 사용자/그룹이 owner | 카탈로그 생성/소유권 이전, 외부 location/storage credential 관리, 모든 카탈로그·스키마·테이블에 대한 메타데이터 권한 |

> **⚠️ 흔한 오해**: Azure 구독 Owner/Contributor 또는 workspace admin이라고 해서
> Databricks account admin이 되는 것은 아닙니다. Account admin은 별도 부트스트랩이 필요합니다.

### 7.2 부트스트랩 (최초 account admin) 절차

Microsoft Learn 공식 문서 요지:

> "For security and organizational integrity, Databricks requires that a **Microsoft Entra ID Global Administrator** establish your account's first account admin role."

1. Microsoft Entra ID **Global Administrator** 권한이 있는 사용자가 <https://accounts.azuredatabricks.net> 접속.
2. AAD 로그인 → 첫 로그인 시 자동으로 해당 Databricks 계정의 account admin이 부여됨.
3. 부여 후에는 Global Administrator 권한이 더 이상 필요 없음 (Account console 접근만 가능하면 됨).
4. 이후 추가 account admin은 account console → **User management** → 대상 사용자 →
   **Roles**에서 위임 가능 (Global Admin 권한 불필요).

> **Azure 구독 Owner/Contributor만으로는 account admin 부트스트랩 불가**. 반드시 Entra ID Global Administrator가 최초 1회 클릭해야 합니다.

### 7.3 Unity Catalog 상태 확인

2023년 11월 9일 이후 생성된 Azure Databricks 워크스페이스는 Unity Catalog가 자동으로
활성화됩니다. 그 이전 워크스페이스이거나 자동 활성화되지 않은 환경만 account admin이
리전별 metastore를 만들고 워크스페이스를 할당해야 합니다.

| 항목 | 설명 |
| --- | --- |
| 자동 활성화 확인 | Catalog Explorer에서 workspace catalog와 `system` catalog 확인 |
| 기존 워크스페이스 업그레이드 | **Account admin**이 metastore 생성/할당 |
| 1개 region 1개 | 같은 region 내 여러 워크스페이스가 하나의 metastore를 공유 가능 |
| 관리형 스토리지 | 자동 활성화 환경은 Databricks 관리형 스토리지를 사용할 수 있음. 외부 ADLS 접근에는 별도 storage credential/access connector 구성 |
| Workspace 연결 | 기존 non-Unity Catalog 워크스페이스를 업그레이드할 때 metastore 할당 필요 |
| 시스템 스키마 | `system.serving.endpoint_usage`, `system.ai_gateway.usage`, `system.access.audit` 등은 기능별 활성화 조건과 account-level 권한이 다르므로 각 시스템 테이블 문서 확인 |
| Metastore admin | 메타스토어 owner 그룹/사용자. 카탈로그 생성·소유권 이전·외부 location 관리 가능 |

> Unity Catalog가 활성화되어 있어야 **AI Gateway 사용량 시스템 테이블·Inference Tables** 등 [§6 운영 모니터링](#6-운영-모니터링-databricks) 및 [심화 문서](docs/databricks-vs-foundry-models.md) §11의 관측 기능이 의미를 갖습니다.

### 7.4 이 샘플 운영 시 필요 권한 매트릭스

| 작업 | 필요한 최소 권한 |
| --- | --- |
| 엔드포인트 호출 (CAN QUERY) | 사용자/SP에 엔드포인트 권한 부여 — workspace admin이 부여 |
| PAT 발급 (이 샘플 동작용) | 본인 사용자 권한 (workspace 설정에서 PAT 허용된 경우) |
| Inference Tables 활성화 | **Workspace admin** + Unity Catalog enabled 워크스페이스 |
| 서빙 엔드포인트 **Enable usage tracking** | **Workspace admin** |
| `system.serving.endpoint_usage` / `system.ai_gateway.usage` 조회 | usage tracking/Preview 활성화 및 **Account admin** 접근 필요 |
| AI Gateway 빌트인 대시보드 import | **Account admin** + SQL Warehouse |
| Metastore 생성/워크스페이스 할당 | **Account admin** |
| 신규 워크스페이스 생성 | Azure Portal/CLI: 구독 **Owner/Contributor** 또는 필요한 custom role. Account console: **Account admin** |

### 7.5 빠른 자가 진단

본인 권한을 1회 호출로 점검:

```bash
# Workspace 레벨 — admins 그룹에 속하면 workspace admin
printf 'header = "Authorization: Bearer %s"\n' "$DATABRICKS_TOKEN" |
  curl --config - -sS "$DATABRICKS_HOST/api/2.0/preview/scim/v2/Me" |
  jq '.groups[].display'

# Entra ID Global Administrator 여부 (부트스트랩 가능자인지)
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/me/memberOf?\$select=displayName" \
  --query "value[?displayName=='Global Administrator']"
```

Account admin 여부는 <https://accounts.azuredatabricks.net> → **User management** → 본인
사용자의 **Roles**에서 확인합니다.

> Databricks 3단계 관리자 권한을 Foundry(단일 Azure RBAC)와 비교한 표는
> [심화 문서](docs/databricks-vs-foundry-models.md) §10 참고.

## 동작 원리

Databricks Foundation Model API는 여러 모델에 공통으로 쓸 수 있는 OpenAI 호환
`/serving-endpoints/chat/completions` 경로를 제공합니다. SDK의 `model`에는
서빙 엔드포인트 이름을 전달합니다. 따라서 URL 리라이트나 LiteLLM 프록시는 필요하지 않습니다.

Agent Framework는 대화 이력의 assistant 메시지에 선택 필드 `name`을 추가하지만, Databricks
Claude는 이 필드를 거부합니다. 아래처럼 해당 필드만 제거하는 최소 훅을 사용합니다.

```python
import json

import httpx
from openai import AsyncOpenAI
from agent_framework.openai import OpenAIChatCompletionClient

async def strip_message_names(request: httpx.Request) -> None:
    if request.method == "POST" and request.content:
        body = json.loads(request.content)
        for message in body.get("messages", []):
            message.pop("name", None)
        content = json.dumps(body).encode()
        request.stream = httpx.ByteStream(content)
        request.headers["content-length"] = str(len(content))

http_client = httpx.AsyncClient(event_hooks={"request": [strip_message_names]})
openai_client = AsyncOpenAI(
    base_url=f"{HOST}/serving-endpoints",
    api_key=DATABRICKS_TOKEN,
    http_client=http_client,
)
client = OpenAIChatCompletionClient(async_client=openai_client, model=ENDPOINT)
agent = client.as_agent(name="ClaudeAgent", instructions="...")
```

Claude Code는 OpenAI 호환 경로가 아니라 provider-native Anthropic Messages API
`/serving-endpoints/anthropic/v1/messages`에 직접 연결합니다. Claude Code가 `/v1/messages`를
붙이므로 `ANTHROPIC_BASE_URL`에는 `https://<workspace>/serving-endpoints/anthropic`을
설정합니다.

## 참고

- [Microsoft Agent Framework — OpenAI-Compatible Endpoints](https://learn.microsoft.com/agent-framework/agents/providers/openai)
- [Databricks Model Serving — OpenAI compatible APIs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/score-foundation-models#openai-client)
- [Foundation Model APIs limits and quotas (rate limits)](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/limits)
- [Databricks 호스팅 모델 vs Microsoft Foundry — 심화 비교·거버넌스·모니터링 (참고 문서)](docs/databricks-vs-foundry-models.md)
- [Claude Code에서 Azure Databricks의 Claude 모델 사용하기 — 네이티브 API 직접 연결 가이드](docs/claude-code-databricks.md)
