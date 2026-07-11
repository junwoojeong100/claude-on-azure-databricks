"""Microsoft Agent Framework + Azure Databricks Claude sample.

Azure Databricks exposes an OpenAI-compatible route at
`/serving-endpoints/chat/completions`. The endpoint name is passed as the
OpenAI `model`, so no URL rewrite or LiteLLM proxy is required.

Agent Framework adds its agent name to replayed assistant messages. Databricks
Claude rejects that optional OpenAI field, so a small request hook removes only
the unsupported message `name` before sending the request.
"""

import asyncio
import itertools
import json
import os
import sys

import httpx
from dotenv import load_dotenv
from openai import AsyncOpenAI

from agent_framework.openai import OpenAIChatCompletionClient

load_dotenv()


async def _strip_unsupported_message_names(request: httpx.Request) -> None:
    if request.method != "POST" or not request.content:
        return

    try:
        body = json.loads(request.content)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return
    if not isinstance(body, dict):
        return

    changed = False
    messages = body.get("messages")
    if isinstance(messages, list):
        for message in messages:
            if isinstance(message, dict) and "name" in message:
                message.pop("name", None)
                changed = True

    if changed:
        new_body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        request.stream = httpx.ByteStream(new_body)
        request.headers["content-length"] = str(len(new_body))


def build_client() -> OpenAIChatCompletionClient:
    workspace = os.environ["DATABRICKS_HOST"].rstrip("/")
    endpoint_name = os.environ["DATABRICKS_SERVING_ENDPOINT"]
    token = os.environ["DATABRICKS_TOKEN"]

    base_url = f"{workspace}/serving-endpoints"

    http_client = httpx.AsyncClient(
        event_hooks={"request": [_strip_unsupported_message_names]},
        timeout=httpx.Timeout(60.0, connect=10.0),
    )

    openai_client = AsyncOpenAI(
        base_url=base_url,
        api_key=token,
        http_client=http_client,
    )

    return OpenAIChatCompletionClient(
        async_client=openai_client,
        model=endpoint_name,
    )


async def _spinner(prefix: str = "[Agent] ", interval: float = 0.08) -> None:
    frames = itertools.cycle("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    try:
        while True:
            sys.stdout.write(f"\r{prefix}{next(frames)} 응답 대기 중…")
            sys.stdout.flush()
            await asyncio.sleep(interval)
    except asyncio.CancelledError:
        sys.stdout.write("\r\033[2K")
        sys.stdout.flush()
        raise


SAMPLE_QUESTIONS = [
    "Azure Databricks Model Serving이 무엇인지 한 문단으로 설명해줘.",
    "Microsoft Agent Framework와 Microsoft Foundry Agent Service의 차이를 비교해줘.",
    "이 샘플처럼 Databricks의 Claude 모델을 호출할 때 주의할 점 3가지를 알려줘.",
]


_ZERO_RATE_LIMIT_ERROR_HINTS = ("rate limit of 0",)


def _looks_like_zero_rate_limit_error(exc: BaseException) -> bool:
    text = str(exc)
    return any(hint in text for hint in _ZERO_RATE_LIMIT_ERROR_HINTS)


def _print_zero_rate_limit_help(endpoint: str) -> None:
    # A 403 "rate limit of 0" is not normal throttling (which returns 429).
    # Point the operator at the documented availability and limit checks.
    print(
        "\n" + "=" * 60 + "\n"
        f"[!] '{endpoint}' 호출이 거부되었습니다 (Databricks-set rate limit of 0).\n\n"
        "일반적인 사용량 초과는 429를 반환합니다. 403과 유효 한도 0 조합은 다음을\n"
        "차례로 확인해야 합니다:\n"
        "  - 현재 workspace region에서 해당 Claude 모델이 지원되는지\n"
        "  - 비 EU/US 리전에서 cross-Geo 처리가 필요한지\n"
        "  - endpoint·사용자·그룹 rate limit이 0으로 설정되지 않았는지\n"
        "  - 모델 호출 권한과 계정별 Anthropic 용량이 활성화됐는지\n\n"
        "Databricks 자체 모델은 성공하고 Claude만 실패하면 모델별 가용성 또는 용량\n"
        "문제일 가능성이 높습니다. 필요한 경우 Azure Databricks account team에\n"
        "현재 account/workspace/model 정보를 전달해 확인하세요.\n" + "=" * 60
    )


async def main() -> None:
    endpoint_name = os.environ["DATABRICKS_SERVING_ENDPOINT"]
    agent = build_client().as_agent(
        name="DatabricksClaudeAgent",
        instructions=(
            f"You are a helpful assistant served by {endpoint_name} "
            "from Azure Databricks Model Serving. "
            "한국어 질문에는 한국어로 답하세요."
        ),
    )

    print(f"Databricks agent ({endpoint_name}) — 대화를 시작합니다.")
    print("종료하려면 빈 줄을 입력하거나 Ctrl-D를 누르세요.")
    print(f"먼저 샘플 질문 {len(SAMPLE_QUESTIONS)}개를 자동으로 실행합니다.\n")

    session = agent.create_session()

    total_input = 0
    total_output = 0
    total_all = 0
    turns = 0

    sample_queue = list(SAMPLE_QUESTIONS)

    try:
        while True:
            if sample_queue:
                user_message = sample_queue.pop(0)
                print(f"[User] {user_message}  (sample)")
            else:
                try:
                    user_message = input("[User] ").strip()
                except EOFError:
                    print()
                    break
                if not user_message:
                    break

            stream = agent.run(user_message, stream=True, session=session)
            spinner_task: asyncio.Task | None = asyncio.create_task(_spinner())
            try:
                async for update in stream:
                    if update.text:
                        if spinner_task is not None:
                            spinner_task.cancel()
                            try:
                                await spinner_task
                            except asyncio.CancelledError:
                                pass
                            spinner_task = None
                            print("[Agent] ", end="", flush=True)
                        print(update.text, end="", flush=True)
            except Exception as exc:  # noqa: BLE001
                if spinner_task is not None and not spinner_task.done():
                    spinner_task.cancel()
                    try:
                        await spinner_task
                    except asyncio.CancelledError:
                        pass
                    spinner_task = None
                if not _looks_like_zero_rate_limit_error(exc):
                    raise
                _print_zero_rate_limit_help(
                    os.environ.get("DATABRICKS_SERVING_ENDPOINT", "?")
                )
                return
            finally:
                if spinner_task is not None and not spinner_task.done():
                    spinner_task.cancel()
                    try:
                        await spinner_task
                    except asyncio.CancelledError:
                        pass
            print()

            response = await stream.get_final_response()
            usage = response.usage_details
            if usage is not None:
                if isinstance(usage, dict):
                    inp = usage.get("input_token_count", 0) or 0
                    out = usage.get("output_token_count", 0) or 0
                    tot = usage.get("total_token_count") or (inp + out)
                else:
                    inp = getattr(usage, "input_token_count", 0) or 0
                    out = getattr(usage, "output_token_count", 0) or 0
                    tot = getattr(usage, "total_token_count", None) or (inp + out)
                total_input += inp
                total_output += out
                total_all += tot
                turns += 1
                print(
                    f"[Tokens] this turn: input={inp} output={out} total={tot}"
                    f"  |  cumulative ({turns} turns): "
                    f"input={total_input} output={total_output} total={total_all}\n"
                )
            else:
                print("[Tokens] (no usage info returned)\n")
    finally:
        if turns:
            print("=" * 60)
            print(
                f"세션 요약 — {turns}턴, "
                f"총 input={total_input}, output={total_output}, "
                f"total={total_all} tokens"
            )


if __name__ == "__main__":
    asyncio.run(main())
