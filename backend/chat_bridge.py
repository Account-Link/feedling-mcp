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

# Persist last_ts across restarts. On 2026-04-20 a restart race with the
# backend caused get_last_ts() to catch a "connection refused" and fall
# back to 0.0, which made the bridge reprocess the entire chat history
# and push a reply to every historical user message. Never again.
STATE_DIR = os.environ.get("FEEDLING_DATA_DIR", "/home/openclaw/feedling-data")
STATE_PATH = os.path.join(STATE_DIR, "chat_bridge_state.json")


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
        "你是 Feedling 里的陪伴助手。用户在 iOS App 聊天框里给你发来一句话。"
        "请用中文给一句简短、有温度、说人话的回复（最多40字）。"
        "优先先接住情绪，再推进一点点对话；在看不清上下文时，也可以用好奇心问一个轻问题。"
        "不要解释系统，不要使用Markdown，不要机器腔。"
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


def load_persisted_last_ts() -> float | None:
    try:
        with open(STATE_PATH, "r") as f:
            return float(json.load(f).get("last_ts", 0))
    except FileNotFoundError:
        return None
    except Exception as e:
        print(f"[chat-bridge] state file unreadable: {e}", flush=True)
        return None


def save_last_ts(ts: float) -> None:
    try:
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"last_ts": ts}, f)
        os.replace(tmp, STATE_PATH)
    except Exception as e:
        print(f"[chat-bridge] could not persist last_ts: {e}", flush=True)


def get_last_ts_blocking() -> float:
    """Block until we can determine last_ts, so we never regress to 0.0
    and spam replies across every historical message."""
    persisted = load_persisted_last_ts()
    if persisted is not None:
        return persisted
    while True:
        try:
            h = get_json(f"{BASE}/v1/chat/history?limit=1")
            msgs = h.get("messages", [])
            ts = float(msgs[-1].get("ts", 0)) if msgs else 0.0
            save_last_ts(ts)
            return ts
        except Exception as e:
            print(f"[chat-bridge] waiting for backend to init last_ts: {e}", flush=True)
            time.sleep(RETRY_SLEEP)


def main():
    last_ts = get_last_ts_blocking()
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
                    save_last_ts(last_ts)
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
