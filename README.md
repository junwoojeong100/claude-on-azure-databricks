# Azure Databricks Claude Agent Sample

[Microsoft Agent Framework](https://learn.microsoft.com/agent-framework/) (Python)
기반으로 **Azure Databricks Model Serving**에 배포된 **Anthropic Claude Opus 4.7**
모델을 사용하는 최소 샘플입니다.

Databricks Foundation Model API의 Anthropic 모델은 OpenAI Chat Completions와
**동일한 페이로드/응답 스키마**를 가지지만, 호출 경로는
`/serving-endpoints/<name>/invocations`만 받습니다. 본 샘플은 OpenAI SDK가
자동으로 붙이는 `/chat/completions` 경로를 httpx event hook으로 `/invocations`로
리라이트한 뒤, 이 클라이언트를 Agent Framework의 `OpenAIChatCompletionClient`에
주입하는 방식으로 동작합니다.

## 1. 사전 준비

1. Azure Databricks 워크스페이스에서 Claude Opus 4.7 Foundation Model API
   엔드포인트 활성화 (예: `databricks-claude-opus-4-7`).
2. 해당 엔드포인트에 **CAN QUERY** 권한이 있는
   [Databricks Personal Access Token (PAT)](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat) 발급.
   - Settings → Developer → Access tokens → Manage → Generate new token
3. Python **3.10 이상** (이 저장소는 3.12로 검증됨)

## 2. 설치

```bash
cd /Users/junwoojeong/GitHub/azure-databricks-claude-agent-sample

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
| `DATABRICKS_SERVING_ENDPOINT` | Claude Opus 4.7가 배포된 서빙 엔드포인트 이름 | `databricks-claude-opus-4-7` |
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

스트리밍으로 응답이 출력된 뒤, 매 턴마다 사용 토큰이 표시되고
빈 줄/Ctrl-D로 종료하면 누적 합계가 출력됩니다.

```
[User] 안녕? 1+1은?
[Agent] 안녕하세요! 1 + 1 = 2 입니다.
[Tokens] this turn: input=1458 output=58 total=139
         | cumulative (1 turns): input=1458 output=58 total=139

[User] 한국의 수도는?
[Agent] 한국(대한민국)의 수도는 서울입니다.
[Tokens] this turn: input=2905 output=124 total=207
         | cumulative (2 turns): input=4363 output=182 total=346

[User]
============================================================
세션 요약 — 2턴, 총 input=4363, output=182, total=346 tokens
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
WHERE endpoint_name = 'databricks-claude-opus-4-7'
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
