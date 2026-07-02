# Azure Databricks Claude Agent Sample

[Microsoft Agent Framework](https://learn.microsoft.com/agent-framework/) (Python)
기반으로 **Azure Databricks Model Serving**에 배포된 **Anthropic Claude Opus 4.8**
모델을 사용하는 최소 샘플입니다.

Databricks Foundation Model API의 Anthropic 모델은 OpenAI Chat Completions와
**동일한 페이로드/응답 스키마**를 가지지만, 호출 경로는
`/serving-endpoints/<name>/invocations`만 받습니다. 본 샘플은 OpenAI SDK가
자동으로 붙이는 `/chat/completions` 경로를 httpx event hook으로 `/invocations`로
리라이트한 뒤, 이 클라이언트를 Agent Framework의 `OpenAIChatCompletionClient`에
주입하는 방식으로 동작합니다.

## 0. 원클릭 자동 설정 (선택)

리소스 그룹 생성부터 워크스페이스·PAT·`.env`·엔드포인트 검증·모델 연결
테스트까지 한 번에 자동화하는 멱등(idempotent) 스크립트를 제공합니다. `az login`이
된 상태에서 실행하세요.

```bash
python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
scripts/setup_databricks_claude.sh
# 이름/리전 변경: RG=my-rg LOCATION=eastus2 WORKSPACE=my-ws scripts/setup_databricks_claude.sh
```

스크립트는 대상 엔드포인트(`databricks-claude-opus-4-8`) 호출을 테스트하고, 만약
`Databricks-set rate limit of 0`으로 막히면(아래 사전 준비 1번 참고) Databricks 자체
호스팅 모델로 파이프라인이 정상 동작함을 함께 검증합니다.

> **주의:** Anthropic Claude 가용성은 **Databricks 계정 = Entra ID 테넌트 단위**로
> 결정됩니다. Anthropic이 활성화되지 않은 테넌트에서는 리전/워크스페이스를 새로
> 만들어도 계속 `rate limit of 0`으로 막힙니다. 이 경우 Anthropic이 활성화된
> 테넌트/구독을 쓰거나, Databricks에 계정 활성화를 요청하세요.

## 1. 사전 준비

1. Azure Databricks 워크스페이스에서 Claude Opus 4.8 Foundation Model API
   엔드포인트 활성화 (예: `databricks-claude-opus-4-8`).
   - Claude 모델은 Databricks에서 **"EU/US 리전" pay-per-token 모델**로 분류됩니다.
     워크스페이스가 EU/US가 아닌 리전(예: `koreacentral`)이면 `databricks-claude-*`
     호출이 `403 PERMISSION_DENIED: ... Databricks-set rate limit of 0`으로 막힐 수
     있습니다. 이때는 **계정 관리자**가 [account console](https://accounts.azuredatabricks.net) →
     **Workspaces → 해당 워크스페이스 → Security and compliance** 탭에서
     **"Enforce data processing within workspace Geography for Designated Services"를
     Off**(= cross-Geo 데이터 처리 허용)로 바꿔야 합니다.
     (인리전 Databricks 자체 호스팅 오픈 모델은 이 설정 없이도 동작합니다.)
2. 해당 엔드포인트에 **CAN QUERY** 권한이 있는
   [Databricks Personal Access Token (PAT)](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat) 발급.
   - Settings → Developer → Access tokens → Manage → Generate new token
3. Python **3.10 이상** (이 저장소는 3.12로 검증됨)

## 2. 설치

```bash
git clone https://github.com/<your-account>/azure-databricks-claude-agent-sample.git
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

내부적으로 다음 URL을 호출합니다:

```
{DATABRICKS_HOST}/serving-endpoints/{DATABRICKS_SERVING_ENDPOINT}/invocations
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
Databricks Claude Opus 4.8 agent — 대화를 시작합니다.
종료하려면 빈 줄을 입력하거나 Ctrl-D를 누르세요.
먼저 샘플 질문 3개를 자동으로 실행합니다.

[User] Azure Databricks Model Serving이 무엇인지 한 문단으로 설명해줘.  (sample)
⠹ 응답 대기 중…
[Agent] Azure Databricks Model Serving은 …
[Tokens] this turn: input=1458 output=58 total=139
         | cumulative (1 turns): input=1458 output=58 total=139

... (샘플 2, 3 자동 실행) ...

[User]                          ← 여기서부터 직접 입력
============================================================
세션 요약 — 3턴, 총 input=4363, output=182, total=346 tokens
```

> 토큰 카운트는 Databricks/Anthropic이 반환하는 `usage` 필드를 그대로 사용합니다.
> 캐시(cache_read / cache_creation) 토큰이 있을 경우 `total`이 단순히
> `input + output`이 아닐 수 있습니다.

### 운영 레벨 모니터링 (Databricks 측)

이 엔드포인트는 AI Gateway의 `usage_tracking_config.enabled = true`가 켜져 있어
다음 위치에서도 자동 집계됩니다.

| 위치 | 용도 |
| --- | --- |
| Databricks UI → Serving → 엔드포인트 상세 페이지 | (Custom / Provisioned Throughput 엔드포인트만) 인프라 헬스 메트릭 차트 |
| Databricks UI → Serving → AI Gateway → **Create / View Dashboard** | 토큰/요청/지연시간/사용자별 빌트인 대시보드 (account admin이 import 필요, 백엔드에 SQL Warehouse 사용) |
| `system.ai_gateway.usage` (AI Gateway Beta) / `system.serving.endpoint_usage` (시스템 테이블) | 사용자/엔드포인트/시간 단위 집계, 비용 분석 (account admin 권한 필요) |
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

## 동작 원리

Databricks Foundation Model API의 Anthropic 모델 엔드포인트는 `api_types`로
`mlflow/v1/chat/completions`, `anthropic/v1/messages`만 노출하며,
OpenAI 호환 경로(`/openai/v1/chat/completions`)는 제공하지 않습니다.
대신 `/serving-endpoints/<name>/invocations`가 OpenAI Chat Completions와
**동일한 요청/응답 스키마**(`messages` 입력, `choices[0].message.content` 응답)를 사용합니다.

따라서 OpenAI SDK가 자동으로 추가하는 `/chat/completions` 경로를
httpx **event hook**으로 `/invocations`로 리라이트한 뒤, 이 클라이언트를
Agent Framework의 `OpenAIChatCompletionClient`에 `async_client=`로 주입합니다.

```python
import httpx
from openai import AsyncOpenAI
from agent_framework.openai import OpenAIChatCompletionClient

async def rewrite(req: httpx.Request) -> None:
    if req.url.path.endswith("/chat/completions"):
        new_path = req.url.path[:-len("/chat/completions")] + "/invocations"
        req.url = req.url.copy_with(path=new_path)

http_client = httpx.AsyncClient(event_hooks={"request": [rewrite]})
openai_client = AsyncOpenAI(
    base_url=f"{HOST}/serving-endpoints/{ENDPOINT}/",
    api_key=DATABRICKS_PAT,
    http_client=http_client,
)
client = OpenAIChatCompletionClient(async_client=openai_client, model=ENDPOINT)
agent = client.as_agent(name="ClaudeAgent", instructions="...")
```

> 만약 사용하시는 엔드포인트가 OpenAI 호환 경로를 직접 노출한다면
> (`api_types`에 `openai/v1/chat/completions` 포함) 위 hook 없이
> `base_url=".../serving-endpoints/<name>/openai/v1/"`만으로 충분합니다.

## 참고

- [Microsoft Agent Framework — OpenAI-Compatible Endpoints](https://learn.microsoft.com/agent-framework/agents/providers/openai)
- [Databricks Model Serving — OpenAI compatible APIs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/score-foundation-models#openai-client)
