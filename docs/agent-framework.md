# Microsoft Agent Framework 실습

이 실습은 Microsoft Agent Framework의 Python `OpenAIChatCompletionClient`로 Azure
Databricks의 Claude 모델을 호출합니다.

```text
Agent Framework
  └─ OpenAI Chat Completions
      └─ https://<workspace>/serving-endpoints/chat/completions
          └─ model: databricks-claude-opus-4-8
```

Databricks의 이 경로는 Chat Completions API이므로, Agent Framework에서 Responses
클라이언트가 아닌 `OpenAIChatCompletionClient`를 사용합니다.

## 사전 준비

[Azure Databricks 환경 설정](azure-databricks-setup.md)을 완료하고 프로젝트 루트의
`.env`에 다음 값이 있어야 합니다.

```dotenv
DATABRICKS_HOST=https://<workspace>.azuredatabricks.net
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<databricks-token>
```

## 설치

macOS/Linux/WSL:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

Windows PowerShell:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Python 3.10 이상이 필요합니다.

## 실행

macOS/Linux/WSL:

```bash
.venv/bin/python src/agent_sample.py
```

Windows PowerShell:

```powershell
.\.venv\Scripts\python.exe src\agent_sample.py
```

`python-dotenv`가 `.env`를 자동으로 읽으므로 별도로 `source .env`를 실행할 필요가
없습니다. 이미 설정된 셸 환경변수가 있으면 그 값이 우선합니다.

## 실행 결과

샘플은 다음 순서로 동작합니다.

1. 한국어 샘플 질문 3개 자동 실행
2. 첫 토큰을 기다리는 동안 spinner 표시
3. 응답 스트리밍
4. 턴별·누적 token 사용량 표시
5. 이후 사용자 입력 모드로 전환

빈 줄 또는 Ctrl-D를 입력하면 종료하고 세션 합계를 출력합니다.

```text
Databricks agent (databricks-claude-opus-4-8) — 대화를 시작합니다.

[User] Azure Databricks Model Serving이 무엇인지 한 문단으로 설명해줘.  (sample)
[Agent] ...
[Tokens] this turn: input=... output=... total=...
```

샘플 질문은 `src/agent_sample.py`의 `SAMPLE_QUESTIONS`에서 변경할 수 있습니다.

## 구현에서 중요한 부분

### 1. Endpoint 이름을 `model`로 전달

```python
openai_client = AsyncOpenAI(
    base_url=f"{workspace}/serving-endpoints",
    api_key=token,
    http_client=http_client,
)

client = OpenAIChatCompletionClient(
    async_client=openai_client,
    model=endpoint_name,
)
```

OpenAI SDK가 `chat/completions`를 붙이고, 요청의 `model`에는
`databricks-claude-opus-4-8` 같은 Databricks endpoint 이름이 들어갑니다.

### 2. 다중 턴의 `name` 필드만 제거

Agent Framework는 이전 assistant 메시지를 다시 보낼 때 선택적 OpenAI `name` 필드를
추가할 수 있습니다. Databricks Claude는 이 필드를 거부하므로 요청 훅이 assistant
메시지의 `name`만 제거합니다.

```python
for message in body.get("messages", []):
    message.pop("name", None)
```

URL이나 응답 형식은 바꾸지 않으며 LiteLLM도 사용하지 않습니다.

## 문제 해결

| 증상 | 해결 |
| --- | --- |
| `KeyError: DATABRICKS_*` | 프로젝트 루트의 `.env` 값 확인 |
| `messages.N.name` 관련 400 | 최신 `src/agent_sample.py`의 request hook 사용 |
| `401` | Workspace URL과 token 확인 |
| `403 ... rate limit of 0` | [환경 설정 가이드의 진단 순서](azure-databricks-setup.md#자주-발생하는-문제) 확인 |
| 첫 턴은 성공하고 두 번째 턴 실패 | `name` 필드 제거 훅이 빠지지 않았는지 확인 |

다음 단계: [Claude Code를 Azure Databricks Claude에 연결](claude-code-databricks.md)
