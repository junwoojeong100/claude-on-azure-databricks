# Claude Code에서 Azure Databricks의 Claude 모델 사용하기

로컬 [Claude Code](https://code.claude.com/) CLI가, Azure Databricks Model
Serving에 배포된 **Anthropic Claude**(예: `databricks-claude-opus-4-8`)를
백엔드로 사용하도록 연결하는 방법을 처음부터 끝까지 설명합니다.

```
Claude Code ──(Anthropic /v1/messages)──► LiteLLM 프록시 ──(OpenAI /invocations)──► Azure Databricks
 (~/.claude/settings.json)                 127.0.0.1:4000                            Claude 모델
```

이 리포의 원클릭 스크립트
[`scripts/setup_claude_code_databricks.sh`](../scripts/setup_claude_code_databricks.sh)로
전체 과정을 자동화할 수 있고, 원리를 이해하며 직접 하려면 [§5 수동 설치](#5-수동-설치-원리-이해용)를
따르세요.

> 📋 요건·주의사항을 빠르게 훑거나 동료·고객·파트너에게 **사전 공유**하려면
> [`claude-code-databricks-checklist.md`](./claude-code-databricks-checklist.md)를 참고하세요.

> 이 문서는 **Claude Code**(터미널 CLI)를 Databricks에 연결하는 내용입니다.
> Databricks의 Claude를 **파이썬 코드**에서 직접 호출하는 최소 샘플은 이 리포의
> [`README.md`](../README.md)와 `src/agent_sample.py`를 참고하세요.

---

## 1. 왜 프록시가 필요한가

Claude Code는 **Anthropic Messages API 형식만** 사용합니다
(`POST /v1/messages`, 응답은 `type:"message"` + `content[]` + `stop_reason`).
반면 Databricks 서빙 엔드포인트는 경로도 형식도 다릅니다.

| | Claude Code가 요구 | Databricks가 제공 |
| --- | --- | --- |
| 경로 | `<base>/v1/messages` | `.../serving-endpoints/<name>/invocations` |
| 요청/응답 형식 | Anthropic Messages | OpenAI Chat Completions (`choices[]`, `object:"chat.completion"`) |

Databricks `/invocations`는 Anthropic 형식으로 보내도 **OpenAI 형식**으로
응답합니다. 두 프로토콜이 호환되지 않으므로 **환경변수 설정만으로는
불가능**하며, 사이에서 형식을 번역하는 **LiteLLM 프록시**가 반드시 필요합니다.

> 참고: `src/agent_sample.py`가 프록시 없이 동작하는 이유는 파이썬 코드 안에서
> httpx 훅으로 경로를 직접 리라이트하기 때문입니다. Claude Code는 닫힌
> 바이너리라 그런 훅 지점이 없어 외부 프록시가 필요합니다.

---

## 2. 사전 준비

1. **Azure Databricks 워크스페이스 + Claude 서빙 엔드포인트**
   - Claude 엔드포인트(예: `databricks-claude-opus-4-8`)가 워크스페이스에
     배포되어 있어야 합니다(Serving → Endpoints).
   - Anthropic Claude는 **계정/지역별 서빙 용량 할당** 대상이라, 할당이 없는
     계정에서는 호출이 `rate limit of 0`(403)으로 막힙니다. 이 경우 Databricks
     account team에 Anthropic 용량 활성화를 요청해야 합니다(고객 설정으로는
     해결 불가). 자세한 내용은 [`README.md`](../README.md)의 문제 해결 절 참고.
2. **Databricks PAT** — 대상 엔드포인트에 **CAN QUERY** 권한이 있는
   [Personal Access Token](https://learn.microsoft.com/azure/databricks/dev-tools/auth/pat).
3. **Claude Code CLI** 설치 및 동작 확인:
   ```bash
   claude --version
   ```
4. **`uv`**(권장) 또는 **Python 3.12**. `uv`가 있으면 환경 구성이 빠릅니다:
   ```bash
   # macOS/Linux
   brew install uv          # 또는: curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
   ```powershell
   # Windows
   winget install astral-sh.uv   # 또는 python.org의 Python 3.12 설치
   ```
5. 자격증명을 담은 `.env` 파일(이 리포 루트). `.env.example`을 복사해 채웁니다:
   ```bash
   cp .env.example .env
   # DATABRICKS_HOST, DATABRICKS_SERVING_ENDPOINT, DATABRICKS_TOKEN 입력
   ```
   > `.env`는 `.gitignore`에 포함되어 커밋되지 않습니다. 절대 커밋하지 마세요.

---

## 3. 빠른 설치 (원클릭)

**A. 이 리포를 이미 클론했고 `.env`가 준비됐다면** — 리포 루트에서 한 줄:

```bash
scripts/setup_claude_code_databricks.sh
```

**B. 리포 클론 없이 한 줄로** — 자격증명만 환경변수로 지정해 실행:

```bash
export DATABRICKS_HOST="https://adb-xxxx.azuredatabricks.net"
export DATABRICKS_TOKEN="dapi..."
export DATABRICKS_SERVING_ENDPOINT="databricks-claude-opus-4-8"
bash <(curl -fsSL https://raw.githubusercontent.com/junwoojeong100/azure-databricks-claude-agent-sample/main/scripts/setup_claude_code_databricks.sh)
```

> `bash`/`zsh`에서 실행하세요(프로세스 치환 `<(...)` 사용). 신선한 환경에서는 첫
> `litellm` 로드가 느려 검증까지 1분 남짓 걸릴 수 있습니다.

위 A·B는 macOS/Linux(bash)용입니다. **Windows(네이티브)는 PowerShell 설치기**를 쓰세요:

**C. Windows (PowerShell)** — 자격증명을 `$env:`로 지정하고 실행:

```powershell
$env:DATABRICKS_HOST = "https://adb-xxxx.azuredatabricks.net"
$env:DATABRICKS_TOKEN = "dapi..."
$env:DATABRICKS_SERVING_ENDPOINT = "databricks-claude-opus-4-8"

# 리포에서:
scripts\setup_claude_code_databricks.ps1

# 리포 없이(임시 파일로 내려받아 실행):
$u = "https://raw.githubusercontent.com/junwoojeong100/azure-databricks-claude-agent-sample/main/scripts/setup_claude_code_databricks.ps1"
$f = "$env:TEMP\cc-setup.ps1"; Invoke-WebRequest -UseBasicParsing $u -OutFile $f; & $f
```

> `.env`가 리포에 있으면 `$env:` 지정 없이 `scripts\setup_claude_code_databricks.ps1`만
> 실행하면 됩니다. Windows에서는 launchd 대신 **작업 스케줄러(Scheduled Task)**로 로그온
> 시 자동 시작을 등록합니다. 실행 정책에 막히면
> `powershell -ExecutionPolicy Bypass -File scripts\setup_claude_code_databricks.ps1`.

스크립트가 하는 일(멱등 — 여러 번 실행해도 안전):

1. `.env`(또는 환경변수)에서 Databricks 자격증명을 읽음
2. `~/.claude-databricks/`에 전용 파이썬 환경을 만들고 `litellm[proxy]` 설치
3. 프록시 설정(`config.yaml`), 자격증명(`.env`, 권한 0600), 실행 스크립트 작성
4. `~/.claude/settings.json`의 `env` 블록을 **병합**(기존 설정 보존)
5. 프록시 시작 — macOS는 launchd 서비스로 자동 시작 등록(로그인 시 실행 +
   크래시 재시작). 그 외 OS는 우선 백그라운드(nohup)로 실행되며, 영구 실행은
   §6의 systemd 설정을 권장
6. 헬스 체크와 `/v1/messages` 왕복 테스트로 검증

완료 후 **새 터미널**을 열고 `claude`를 실행하면 Databricks의 Claude로
동작합니다.

### 자격증명을 환경변수로 전달(선택)

`.env` 대신 환경변수로 넘길 수도 있습니다:

```bash
DATABRICKS_HOST=https://adb-xxxx.azuredatabricks.net \
DATABRICKS_TOKEN=dapi... \
DATABRICKS_SERVING_ENDPOINT=databricks-claude-opus-4-8 \
scripts/setup_claude_code_databricks.sh
```

### 설정 가능한 환경변수(기본값)

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `PROXY_DIR` | `~/.claude-databricks` | 프록시 설치 위치 |
| `PORT` | `4000` | 로컬 프록시 포트 |
| `MASTER_KEY` | `sk-databricks-local` | Claude Code→프록시 로컬 키 |
| `AUTOSTART` | `1` | `0`이면 서비스 미등록(수동 실행) |
| `LAUNCHD_LABEL` | `com.databricks.claude-proxy` | launchd 라벨 |
| `CLAUDE_SETTINGS` | `~/.claude/settings.json` | Claude Code 설정 경로 |
| `ENV_FILE` | 리포 `.env` | 자격증명 소스 파일 |
| `FORCE` | `0` | `1`이면 litellm 재설치 |
| `DATABRICKS_FAST_ENDPOINT` | `databricks-claude-haiku-4-5` | 분류기(small/fast) 모델 엔드포인트 |
| `DATABRICKS_MODELS` | opus-4-8, sonnet-5, haiku-4-5 | 프록시에 등록할 **선택 가능한 메인 모델** 목록(공백/콤마 구분). Claude Code `/model <이름>`으로 전환 |

---

## 4. 설치 결과물

| 위치 | 역할 |
| --- | --- |
| `~/.claude-databricks/config.yaml` | LiteLLM 라우팅. 선택 가능한 메인 모델들(기본: Opus 4.8 · Sonnet 5 · Haiku 4.5) + 분류기(small/fast) + 와일드카드 `*`를 각 `databricks/<endpoint>`로 매핑 |
| `~/.claude-databricks/custom_handlers.py` | 프리콜 훅 — Databricks가 거부하는 `thinking_blocks`/`reasoning_content` 제거 + `stop_sequences` → `stop` 변환 |
| `~/.claude-databricks/.env` (0600) | 프록시 전용 자격증명(`DATABRICKS_API_KEY`/`DATABRICKS_API_BASE`/`LITELLM_MASTER_KEY`) |
| `~/.claude-databricks/start-proxy.sh` (Windows는 `start-proxy.ps1`) | 프록시 실행 스크립트 |
| `~/.claude-databricks/.venv/` | LiteLLM 전용 파이썬 환경 |
| `~/.claude-databricks/proxy.log` | 실행/요청 로그 |
| `~/Library/LaunchAgents/com.databricks.claude-proxy.plist` | (macOS) 자동 시작 서비스 — Windows는 작업 스케줄러 `ClaudeDatabricksProxy` |
| `~/.claude/settings.json` | Claude Code를 프록시로 향하게 하는 `env` 블록 |

`~/.claude/settings.json`의 `env` 블록:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_AUTH_TOKEN": "sk-databricks-local",
    "ANTHROPIC_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_SMALL_FAST_MODEL": "databricks-claude-haiku-4-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "databricks-claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "databricks-claude-sonnet-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "databricks-claude-haiku-4-5"
  }
}
```

- `ANTHROPIC_AUTH_TOKEN`은 Claude Code가 이 **로컬 프록시**에 제시하는 키이며
  `config.yaml`의 `master_key`와 일치해야 합니다(클라우드 비밀 아님).
- 이 토큰이 활성인 동안 Claude Code는 claude.ai 구독 대신 프록시(→ Databricks)를
  사용합니다.
- `ANTHROPIC_SMALL_FAST_MODEL`은 Claude Code가 요약·제목 생성·분류(classifier) 등
  가벼운 백그라운드 작업에 쓰는 **small/fast 모델**입니다. 기본값은 가벼운
  `databricks-claude-haiku-4-5`이며 `DATABRICKS_FAST_ENDPOINT`로 바꿀 수 있습니다.
  이 값은 Claude Code 시작 시 로드되므로, 변경하면 Claude Code를 재시작해야 반영됩니다.
- `ANTHROPIC_MODEL`은 **기본 메인 모델**입니다. 설치기는 선택 가능한 메인 모델
  (기본: `databricks-claude-opus-4-8` · `databricks-claude-sonnet-5` ·
  `databricks-claude-haiku-4-5`)을 모두 `config.yaml`에 등록하므로, Claude Code
  안에서 **`/model <이름>`**으로 실행 중에 전환할 수 있습니다(예:
  `/model databricks-claude-sonnet-5`). 등록 목록은 `DATABRICKS_MODELS`로 바꿉니다.
  > catch-all `*`은 **등록되지 않은** 모델명만 기본 메인으로 보냅니다. 그래서
  > `/model`로 전환하려는 모델은 반드시 `config.yaml`에 등록돼 있어야 합니다.
- `ANTHROPIC_DEFAULT_OPUS_MODEL` · `ANTHROPIC_DEFAULT_SONNET_MODEL` ·
  `ANTHROPIC_DEFAULT_HAIKU_MODEL`은 `/model` 선택기의 **내장 Opus/Sonnet/Haiku
  프리셋**을 각 Databricks 모델로 연결합니다. 프리셋을 고르면 Databricks 모델로
  라우팅되고, 선택기에 `databricks-claude-*` id가 표시되어 **native Claude 모델과
  구분**됩니다. (설치기가 `DATABRICKS_MODELS`에서 opus/sonnet/haiku를 자동 매핑)

---

## 5. 수동 설치 (원리 이해용)

스크립트 없이 직접 구성하려면:

```bash
# 1) 프록시 디렉터리 + 전용 환경
mkdir -p ~/.claude-databricks && cd ~/.claude-databricks
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python "litellm[proxy]"

# 2) 자격증명 파일 (권한 0600)
umask 077
cat > .env <<'EOF'
DATABRICKS_API_KEY=<your-databricks-pat>
DATABRICKS_API_BASE=https://<workspace>.azuredatabricks.net/serving-endpoints
LITELLM_MASTER_KEY=sk-databricks-local
EOF
chmod 600 .env
umask 022

# 3) 라우팅 설정
cat > config.yaml <<'EOF'
model_list:
  # 선택 가능한 메인 모델 (Claude Code /model <이름>으로 전환; ANTHROPIC_MODEL이 기본)
  - model_name: databricks-claude-opus-4-8
    litellm_params:
      model: databricks/databricks-claude-opus-4-8
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE
  - model_name: databricks-claude-sonnet-5
    litellm_params:
      model: databricks/databricks-claude-sonnet-5
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE
  # 분류기(small/fast) 모델 (ANTHROPIC_SMALL_FAST_MODEL) — Haiku 4.5는 메인 선택지로도 사용 가능
  - model_name: databricks-claude-haiku-4-5
    litellm_params:
      model: databricks/databricks-claude-haiku-4-5
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE
  # 등록되지 않은 모델명은 모두 기본 메인 엔드포인트로
  - model_name: "*"
    litellm_params:
      model: databricks/databricks-claude-opus-4-8
      api_key: os.environ/DATABRICKS_API_KEY
      api_base: os.environ/DATABRICKS_API_BASE
litellm_settings:
  drop_params: true
  callbacks: custom_handlers.proxy_handler_instance
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF

# 3b) 호환 훅 (Databricks가 거부하는 thinking_blocks/reasoning_content 제거 +
#     Anthropic stop_sequences → OpenAI stop 변환)
cat > custom_handlers.py <<'PYEOF'
from litellm.integrations.custom_logger import CustomLogger

_THINKING_TYPES = {"thinking", "redacted_thinking"}


class DatabricksCompatHook(CustomLogger):
    @staticmethod
    def _fix_stop(c):
        # Databricks는 Anthropic의 stop_sequences를 거부 → OpenAI식 stop으로 변환
        # (공백만 있는 시퀀스는 제거하고, 남는 게 없으면 stop 자체를 생략)
        if not isinstance(c, dict) or "stop_sequences" not in c:
            return
        seq = c.pop("stop_sequences")
        if isinstance(seq, str):
            seq = [seq]
        seq = [s for s in seq if isinstance(s, str) and s.strip()] if isinstance(seq, list) else None
        if seq and not c.get("stop"):
            c["stop"] = seq

    def _clean(self, data):
        if not isinstance(data, dict):
            return data
        self._fix_stop(data)
        self._fix_stop(data.get("optional_params"))
        for msg in (data.get("messages") or []):
            if not isinstance(msg, dict):
                continue
            msg.pop("thinking_blocks", None)
            msg.pop("reasoning_content", None)
            content = msg.get("content")
            if isinstance(content, list):
                kept = [b for b in content
                        if not (isinstance(b, dict) and b.get("type") in _THINKING_TYPES)]
                msg["content"] = kept if kept else ""
        return data

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        return self._clean(data)


proxy_handler_instance = DatabricksCompatHook()
PYEOF

# 4) 실행 스크립트
cat > start-proxy.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$HOME/.claude-databricks"
set -a; . "$DIR/.env"; set +a
exec "$DIR/.venv/bin/litellm" --config "$DIR/config.yaml" --host 127.0.0.1 --port 4000
EOF
chmod +x start-proxy.sh
```

Claude Code 설정(`~/.claude/settings.json`)에 [§4의 `env` 블록](#4-설치-결과물)을
추가합니다(기존 파일이 있으면 `env` 키만 병합).

엔드포인트 이름이 다르면 `config.yaml`의 `databricks/<endpoint>`와 설정의
`ANTHROPIC_MODEL`(메인)·`ANTHROPIC_SMALL_FAST_MODEL`(분류기)을 실제 엔드포인트
이름으로 바꾸세요.

---

## 6. 자동 시작 관리

### macOS (launchd)

```bash
# 상태 / 로그
launchctl list | grep claude-proxy
tail -f ~/.claude-databricks/proxy.log

# 중지 / 시작 / 재시작
launchctl unload ~/Library/LaunchAgents/com.databricks.claude-proxy.plist
launchctl load -w ~/Library/LaunchAgents/com.databricks.claude-proxy.plist
```

> `config.yaml`이나 `.env`를 바꾼 뒤에는 **재시작**(unload → load)해야 반영됩니다.

### Linux (systemd --user, 참고)

원클릭 스크립트는 비-macOS에서 프록시를 nohup으로만 임시 실행합니다(관리되지 않아
재부팅·크래시 후 자동 복구되지 않음). 영구 실행·자동 복구가 필요하면 아래 systemd
user 서비스를 설정하세요.

`~/.config/systemd/user/claude-databricks.service`:

```ini
[Unit]
Description=Claude Code -> Databricks LiteLLM proxy

[Service]
ExecStart=%h/.claude-databricks/start-proxy.sh
Restart=always

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now claude-databricks.service
loginctl enable-linger "$USER"   # 로그아웃 후에도 유지
```

### Windows (작업 스케줄러)

Windows용 설치기
[`scripts\setup_claude_code_databricks.ps1`](../scripts/setup_claude_code_databricks.ps1)는
로그온 시 자동 시작되는 **작업 스케줄러(Scheduled Task)** `ClaudeDatabricksProxy`를
등록합니다.

```powershell
# 상태 / 시작 / 중지
Get-ScheduledTask -TaskName ClaudeDatabricksProxy
Start-ScheduledTask -TaskName ClaudeDatabricksProxy
Stop-ScheduledTask  -TaskName ClaudeDatabricksProxy

# 로그
Get-Content "$env:USERPROFILE\.claude-databricks\proxy.log" -Tail 20 -Wait

# 제거
Unregister-ScheduledTask -TaskName ClaudeDatabricksProxy -Confirm:$false
```

> 파일 위치는 `%USERPROFILE%\.claude-databricks\`, Claude Code 설정은
> `%USERPROFILE%\.claude\settings.json`입니다. WSL을 쓰는 경우 위 Linux(systemd)
> 방식을 대신 사용하세요.

---

## 7. 수동 실행

자동 시작을 쓰지 않을 때(설치 시 `AUTOSTART=0`) 또는 서비스를 내린 상태에서:

```bash
# 서비스가 떠 있으면 먼저 내려 포트 충돌을 피합니다(macOS 예)
launchctl unload ~/Library/LaunchAgents/com.databricks.claude-proxy.plist 2>/dev/null

# 포그라운드 실행 (Ctrl-C로 종료)
~/.claude-databricks/start-proxy.sh
```

> ⚠️ 자동 시작 서비스와 수동 실행을 동시에 하면 둘 다 같은 포트를 잡으려다
> `Address already in use`로 실패합니다. 한 번에 하나만 실행하세요.
>
> Windows: `Stop-ScheduledTask -TaskName ClaudeDatabricksProxy` 후
> `powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-databricks\start-proxy.ps1"`.

---

## 8. 동작 확인

```bash
# 프록시 헬스 (둘 다 200)
curl -s -o /dev/null -w "liveliness %{http_code}\n" http://127.0.0.1:4000/health/liveliness
curl -s -o /dev/null -w "readiness  %{http_code}\n" http://127.0.0.1:4000/health/readiness

# Anthropic /v1/messages 왕복 (네이티브 Anthropic 형식 응답 확인)
curl -s http://127.0.0.1:4000/v1/messages \
  -H "Authorization: Bearer sk-databricks-local" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"databricks-claude-opus-4-8","max_tokens":40,
       "messages":[{"role":"user","content":"Reply with: PROXY OK"}]}'

# Claude Code 종단 간
claude -p "In 8 words, say hello and name the model serving you."
```

Claude Code 안에서 `/status`를 실행하면 `Anthropic base URL`이
`http://127.0.0.1:4000`, 자격증명이 `ANTHROPIC_AUTH_TOKEN`으로 표시됩니다.

---

## 9. 문제 해결

| 증상 | 원인 / 해결 |
| --- | --- |
| `claude` 연결 오류 / 무응답 | 프록시가 꺼짐. `launchctl list \| grep claude-proxy` 확인 후 로드, 또는 §7 수동 실행. `proxy.log` 확인. |
| `Address already in use` | 같은 포트를 쓰는 인스턴스 중복(서비스 + 수동). `lsof -nP -iTCP:4000 -sTCP:LISTEN -t`로 PID 확인 후 하나만 남김. |
| `403` / `rate limit of 0` | Databricks 계정에 Anthropic 서빙 용량 미할당(고객 설정으로 해결 불가). `README.md` 문제 해결 절 참고. |
| `messages.N.thinking_blocks: Extra inputs are not permitted` | Claude Code가 이력에 재전송한 thinking 블록을 Databricks가 거부. `custom_handlers.py`(프리콜 훅)가 제거합니다 — 이 파일이 있고 `config.yaml`에 `callbacks`가 설정됐는지 확인 후 프록시 재시작. |
| `Cannot specify parameter stop_sequences, use stop instead` | Claude Code(특히 분류기/백그라운드 호출)가 보내는 Anthropic `stop_sequences`를 Databricks가 거부. `custom_handlers.py`(프리콜 훅)가 이를 `stop`으로 변환합니다 — 이 파일이 최신인지(§4/§5) 확인 후 프록시 재시작. |
| `401` / 인증 실패 | ① Claude Code의 `ANTHROPIC_AUTH_TOKEN`과 `config.yaml`의 `master_key` 불일치, 또는 ② `.env`의 Databricks 토큰 만료/무효. 갱신 후 프록시 재시작. |
| `.env` 변경 미반영 | 프록시 재시작 필요(§6). 프로세스는 시작 시점에만 `.env`를 읽음. |
| 로그 위치 | `~/.claude-databricks/proxy.log` |

---

## 10. 업데이트 / 되돌리기

```bash
# LiteLLM 업데이트
uv pip install --python ~/.claude-databricks/.venv/bin/python -U "litellm[proxy]"
# 이후 프록시 재시작(§6)

# 원래 Claude(구독)로 되돌리기
launchctl unload ~/Library/LaunchAgents/com.databricks.claude-proxy.plist   # macOS
#  그리고 ~/.claude/settings.json 의 "env" 블록 제거

# 완전 제거
rm ~/Library/LaunchAgents/com.databricks.claude-proxy.plist
rm -rf ~/.claude-databricks
```

Windows(PowerShell):

```powershell
# LiteLLM 업데이트
uv pip install --python "$env:USERPROFILE\.claude-databricks\.venv\Scripts\python.exe" -U "litellm[proxy]"

# 되돌리기: 작업 스케줄러 제거 + settings의 env 블록 제거
Stop-ScheduledTask -TaskName ClaudeDatabricksProxy
Unregister-ScheduledTask -TaskName ClaudeDatabricksProxy -Confirm:$false
#  그리고 %USERPROFILE%\.claude\settings.json 의 "env" 블록 제거

# 완전 제거
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-databricks"
```

---

## 11. 주의사항

- 프록시는 `127.0.0.1`(로컬호스트)에만 바인딩되어 외부 접근 불가.
- `sk-databricks-local`은 로컬 전용 키이며 클라우드 비밀이 아님.
- 실제 비밀(Databricks 토큰)은 `~/.claude-databricks/.env`(0600)에 저장되며, 리포 `.env`로
  설치했다면 거기에도 있습니다. 두 파일 모두 커밋 금지(리포 `.env`는 `.gitignore`로 제외).
- 도구 호출·스트리밍은 LiteLLM이 Anthropic↔OpenAI로 번역합니다. 대부분 정상
  동작하지만 포맷 차이로 드물게 엣지 케이스가 있을 수 있으니 이상 시 `proxy.log`를
  먼저 확인하세요.
