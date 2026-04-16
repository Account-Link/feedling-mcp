#!/usr/bin/env python3
import json
import os
import subprocess
import time
import urllib.request
from urllib.error import URLError, HTTPError

BASE = os.environ.get("FEEDLING_API_URL", "http://127.0.0.1:5001")
POLL_TIMEOUT = 25
RETRY_SLEEP = 2


def get_json(url: str):
    with urllib.request.urlopen(url, timeout=POLL_TIMEOUT + 10) as r:
        return json.loads(r.read().decode("utf-8"))


def post_json(url: str, payload: dict):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))


def extract_reply(raw: str) -> str:
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    cleaned = []
    for ln in lines:
        if ln.startswith("session_id:"):
            continue
        if ln.startswith("╭") or ln.startswith("╰"):
            continue
        if "Hermes" in ln and ln.startswith("│"):
            continue
        cleaned.append(ln)
    if not cleaned:
        return "我在，刚刚短暂掉线了。你继续说，我会跟上。"
    return cleaned[0][:280]


def generate_reply(user_text: str) -> str:
    prompt = (
        "你是 Feedling 里的小哆啦。用户在 iOS App 聊天框里给你发来一句话。"
        "请用中文给一句简短、有温度、不过度油腻的回复（最多40字）。"
        "不要解释系统，不要使用Markdown。"
        f"\n用户消息：{user_text}"
    )
    try:
        cp = subprocess.run(
            ["hermes", "chat", "-Q", "-q", prompt, "--source", "tool"],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        output = (cp.stdout or "") + "\n" + (cp.stderr or "")
        reply = extract_reply(output)
        if not reply:
            reply = "收到，我在。"
        return reply
    except Exception:
        return "收到，我在。"


def get_last_ts() -> float:
    try:
        h = get_json(f"{BASE}/v1/chat/history?limit=1")
        msgs = h.get("messages", [])
        if msgs:
            return float(msgs[-1].get("ts", 0))
    except Exception:
        pass
    return 0.0


def main():
    last_ts = get_last_ts()
    print(f"[chat-bridge] start with last_ts={last_ts}", flush=True)

    while True:
        try:
            polled = get_json(f"{BASE}/v1/chat/poll?since={last_ts}&timeout={POLL_TIMEOUT}")
            msgs = polled.get("messages", [])
            if not msgs:
                continue

            for m in msgs:
                ts = float(m.get("ts", 0))
                if ts > last_ts:
                    last_ts = ts
                if m.get("role") != "user":
                    continue
                user_text = (m.get("content") or "").strip()
                if not user_text:
                    continue

                reply = generate_reply(user_text)
                post_json(f"{BASE}/v1/chat/response", {"content": reply})
                print(f"[chat-bridge] user='{user_text[:40]}' -> reply='{reply[:40]}'", flush=True)

        except (URLError, HTTPError, TimeoutError, json.JSONDecodeError) as e:
            print(f"[chat-bridge] network error: {e}", flush=True)
            time.sleep(RETRY_SLEEP)
        except Exception as e:
            print(f"[chat-bridge] unexpected error: {e}", flush=True)
            time.sleep(RETRY_SLEEP)


if __name__ == "__main__":
    main()
