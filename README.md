# Claude on Azure Databricks

Azure Databricks가 호스팅하는 Anthropic Claude를 다음 두 방식으로 사용하는 실습
리포지토리입니다.

1. **Microsoft Agent Framework**에서 OpenAI 호환 Chat Completions API 호출
2. **Claude Code**에서 네이티브 Anthropic Messages API 직접 호출

가장 중요한 결과는 Claude Code를 Databricks Claude에 직접 연결하는 것입니다.
LiteLLM, 로컬 프록시, 별도 포트는 필요하지 않습니다.

> 최종 검증: 2026-07-12. 모델과 리전 가용성, 쿼터, Preview 기능은 변경될 수 있으므로
> 운영 적용 전 링크된 공식 문서를 다시 확인하세요.

## 실습 흐름

```text
1. Azure Databricks 준비
   └─ workspace, Claude model, authentication, .env

2. Microsoft Agent Framework 테스트
   └─ /serving-endpoints/chat/completions

3. Claude Code 연결 및 테스트
   └─ /serving-endpoints/anthropic/v1/messages
```

| 목적 | 가이드 |
| --- | --- |
| Azure 리소스 생성 또는 기존 workspace 준비 | [Azure Databricks 환경 설정](docs/azure-databricks-setup.md) |
| Python Agent Framework 샘플 실행 | [Microsoft Agent Framework 실습](docs/agent-framework.md) |
| Claude Code 자동·수동 설정 | [Claude Code 직접 연결 가이드](docs/claude-code-databricks.md) |
| 배포 전 요구사항 검토 | [Claude Code 체크리스트](docs/claude-code-databricks-checklist.md) |
| 인증, 모델 fallback, gateway, LiteLLM 마이그레이션 | [Claude Code 상세 참고](docs/claude-code-databricks-reference.md) |
| Databricks와 Microsoft Foundry 비교 | [모델·거버넌스·비용 비교](docs/databricks-vs-foundry-models.md) |

## 가장 빠른 전체 실습

macOS, Linux 또는 WSL 기준입니다.

```bash
git clone https://github.com/junwoojeong100/claude-on-azure-databricks.git
cd claude-on-azure-databricks

python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt

az extension add --name databricks --upgrade
az login

# workspace, PAT, .env, API 검증, Agent Framework 샘플
scripts/setup_databricks_claude.sh

# Claude Code 직접 연결 설정과 종단 간 검증
unset ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
scripts/setup_claude_code_databricks.sh
```

필요한 기본 도구는 Azure CLI, `curl`, Python 3.10 이상, Git, Claude Code입니다.
Azure 리소스를 만들려면 대상 구독에 Contributor 또는 동등한 권한이 필요합니다.

Windows에서 Claude Code만 설정하려면 다음 PowerShell 스크립트를 사용합니다.

```powershell
Remove-Item Env:ANTHROPIC_AUTH_TOKEN, Env:ANTHROPIC_API_KEY `
  -ErrorAction SilentlyContinue
powershell -ExecutionPolicy Bypass `
  -File .\scripts\setup_claude_code_databricks.ps1
```

> `setup_databricks_claude.sh`는 macOS/Linux/WSL용입니다. Windows에서는 WSL을
> 사용하거나 [Azure Databricks 환경 설정](docs/azure-databricks-setup.md)의 기존
> workspace 경로를 따르세요.

## 기존 Azure Databricks를 사용하는 경우

`.env.example`을 복사하고 자신의 workspace 정보만 입력합니다.

```bash
cp .env.example .env
chmod 600 .env
```

```dotenv
DATABRICKS_HOST=https://<workspace>.azuredatabricks.net
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8
DATABRICKS_TOKEN=<model-query-permission이-있는-token>
```

Windows PowerShell에서는 다음처럼 현재 사용자만 `.env`를 수정할 수 있게 제한합니다.

```powershell
Copy-Item .env.example .env
icacls .env /inheritance:r /grant:r "${env:USERNAME}:(M)"
```

그다음 각 실습을 실행합니다.

```bash
# Agent Framework
.venv/bin/python src/agent_sample.py

# Claude Code
scripts/setup_claude_code_databricks.sh
```

Claude Code 설치기의 기본 후보는 Opus/Sonnet/Haiku입니다. Fable 5는 trust and safety
목적으로 프롬프트와 응답을 30일 보존하며 일부 요청은 사람 검토 대상이 될 수 있으므로,
정책을 승인한 경우에만 명시적으로 추가하세요.

```bash
DATABRICKS_MODELS="databricks-claude-opus-4-8 databricks-claude-sonnet-5 databricks-claude-haiku-4-5 databricks-claude-fable-5" \
  scripts/setup_claude_code_databricks.sh
```

## 두 API 경로를 구분해야 하는 이유

| 사용 대상 | API | 모델 지정 방식 |
| --- | --- | --- |
| Microsoft Agent Framework 샘플 | `/serving-endpoints/chat/completions` | 요청의 `model`에 Databricks endpoint 이름 전달 |
| Claude Code | `/serving-endpoints/anthropic/v1/messages` | Anthropic Messages 요청의 `model`에 Databricks Claude ID 전달 |

Agent Framework가 다중 턴 assistant 메시지에 추가하는 선택적 `name` 필드는
Databricks Claude가 거부하므로 `src/agent_sample.py`의 최소 httpx 훅이 그 필드만
제거합니다. Claude Code는 네이티브 Anthropic 경로를 사용하므로 이런 프로토콜 변환이
필요하지 않습니다.

## 리포지토리 구성

```text
.
├── README.md
├── docs/
│   ├── azure-databricks-setup.md
│   ├── agent-framework.md
│   ├── claude-code-databricks.md
│   ├── claude-code-databricks-reference.md
│   ├── claude-code-databricks-checklist.md
│   └── databricks-vs-foundry-models.md
├── scripts/
│   ├── setup_databricks_claude.sh
│   ├── setup_claude_code_databricks.sh
│   └── setup_claude_code_databricks.ps1
└── src/
    └── agent_sample.py
```

## 보안과 비용

- `.env`와 생성된 token helper 파일을 커밋하지 마세요.
- 자동 생성 PAT는 로컬 실습용입니다. 운영 환경은 서비스 주체 OAuth M2M을 권장합니다.
- 기본 workspace는 Premium SKU이며 Claude는 pay-per-token 모델입니다.
- 실습용 리소스 그룹 전체가 불필요하면 삭제합니다.

```bash
az group delete -n rg-databricks-claude --yes --no-wait
```

## 공식 문서

- [Azure Databricks provider native APIs](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/provider-native-apis)
- [Azure Databricks Anthropic Messages API](https://learn.microsoft.com/azure/databricks/machine-learning/model-serving/query-anthropic-messages)
- [Databricks-hosted foundation models](https://learn.microsoft.com/azure/databricks/machine-learning/foundation-model-apis/supported-models)
- [Microsoft Agent Framework OpenAI provider](https://learn.microsoft.com/agent-framework/agents/providers/openai)
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config)
