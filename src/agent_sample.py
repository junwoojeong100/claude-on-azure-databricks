"""
Microsoft Agent Framework + Azure Databricks (Claude Opus 4.7) 샘플.

Databricks Foundation Model API는 OpenAI Chat Completions와 동일한 페이로드/응답
포맷을 가지지만, 경로는 `/serving-endpoints/<name>/invocations`만 받습니다
(Anthropic 모델의 경우 `api_types`: mlflow/v1/chat/completions, anthropic/v1/messages).

따라서 OpenAI SDK가 자동으로 붙이는 `/chat/completions`를 httpx event hook으로
`/invocations`로 리라이트한 뒤, 그 클라이언트를 Agent Framework의
`OpenAIChatCompletionClient`에 주입합니다.
"""

import asyncio
import itertools
import os
import sys

import httpx
from dotenv import load_dotenv
from openai import AsyncOpenAI

from agent_framework.openai import OpenAIChatCompletionClient

load_dotenv()


async def _rewrite_to_invocations(request: httpx.Request) -> None:
    if request.url.path.endswith("/chat/completions"):
        new_path = request.url.path[: -len("/chat/completions")] + "/invocations"
        request.url = request.url.copy_with(path=new_path)


def build_client() -> OpenAIChatCompletionClient:
    workspace = os.environ["DATABRICKS_HOST"].rstrip("/")
    endpoint_name = os.environ["DATABRICKS_SERVING_ENDPOINT"]
    token = os.environ["DATABRICKS_TOKEN"]

    base_url = f"{workspace}/serving-endpoints/{endpoint_name}/"

    http_client = httpx.AsyncClient(
        event_hooks={"request": [_rewrite_to_invocations]},
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


async def main() -> None:
    agent = build_client().as_agent(
        name="DatabricksClaudeAgent",
        instructions=(
            "You are a helpful assistant powered by Claude Opus 4.7 "
            "served from Azure Databricks Model Serving. "
            "한국어 질문에는 한국어로 답하세요."
        ),
    )

    print("Databricks Claude Opus 4.7 agent — 대화를 시작합니다.")
    print("종료하려면 빈 줄을 입력하거나 Ctrl-D를 누르세요.")
    print(f"먼저 샘플 질문 {len(SAMPLE_QUESTIONS)}개를 자동으로 실행합니다.\n")

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

            stream = agent.run(user_message, stream=True)
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
                f"총 input={total_input}, output={total_output}, total={total_all} tokens"
            )


if __name__ == "__main__":
    asyncio.run(main())
