"""Bounded, opt-in compatibility probe. Never prints keys, bodies or replies.

Set WOOW_MODEL_TEST_BASE_URL / WOOW_MODEL_TEST_MODEL. Supply the key via
WOOW_MODEL_TEST_API_KEY or the hidden terminal prompt; never command arguments.
This is a transport probe, not an iOS UI test.
"""
import argparse
import getpass
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class RejectRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def probe(stream, base_url, model, key):
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("invalid_configuration")
    body = {"model": model, "messages": [{"role": "user", "content": "Reply with exactly WOOW_OK and nothing else."}],
            "stream": stream, "max_tokens": 64}
    request = urllib.request.Request(base_url.rstrip("/") + "/chat/completions",
                                     data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "User-Agent": "WoowAssistant-CompatibilityTest/0.1",
                                              "Accept": "text/event-stream" if stream else "application/json"})
    started = time.monotonic()
    opener = urllib.request.build_opener(RejectRedirect())
    result = {"mode": "sse" if stream else "json", "passed": False}
    try:
        with opener.open(request, timeout=30) as response:
            result["http_status"] = response.status
            if not stream:
                data = response.read(2_000_001)
                if len(data) > 2_000_000:
                    raise ValueError("oversized_response")
                payload = json.loads(data)
                content = payload["choices"][0]["message"]["content"]
                result["reply_characters"] = len(content)
                result["passed"] = content.strip() == "WOOW_OK"
                result["matches_expected_marker"] = result["passed"]
                usage = payload.get("usage") or {}
                result["usage"] = {k: v for k, v in usage.items()
                                   if k in ("prompt_tokens", "completion_tokens", "total_tokens") and isinstance(v, int)}
            else:
                if "text/event-stream" not in response.headers.get("Content-Type", ""):
                    raise ValueError("unexpected_stream_content_type")
                chunks, text, total, done = 0, "", 0, False
                while time.monotonic() - started < 90:
                    line = response.readline(65537)
                    total += len(line)
                    if len(line) > 65536 or total > 2_000_000:
                        raise ValueError("oversized_stream")
                    if not line:
                        break
                    if not line.startswith(b"data:"):
                        continue
                    data = line[5:].strip()
                    if data == b"[DONE]":
                        done = True
                        break
                    payload = json.loads(data)
                    choices = payload.get("choices", [])
                    if choices:
                        delta = choices[0].get("delta", {}).get("content")
                        if isinstance(delta, str):
                            text += delta
                            chunks += 1
                result.update(content_chunks=chunks, reply_characters=len(text), saw_done=done,
                              matches_expected_marker=text.strip() == "WOOW_OK")
                result["passed"] = done and text.strip() == "WOOW_OK" and chunks > 0
    except urllib.error.HTTPError as error:
        result.update(http_status=error.code, error="http_error")
        result["server"] = error.headers.get("Server", "unknown")
        result["content_type"] = error.headers.get("Content-Type", "unknown")
        try:
            raw_error = error.read(8192).decode("utf-8", errors="replace")
            payload = json.loads(raw_error)
            detail = payload.get("error", payload)
            if isinstance(detail, dict):
                for field in ("type", "code", "message"):
                    if isinstance(detail.get(field), (str, int)):
                        result["api_error_" + field] = str(detail[field]).replace(key, "[redacted]")[:240]
        except (ValueError, AttributeError):
            result["html_challenge"] = any(marker in raw_error.lower() for marker in ("cloudflare", "challenge", "access denied"))
    except Exception as error:
        # Exception descriptions may include a URL or response data; emit only type.
        result["error"] = type(error).__name__
    result["elapsed_seconds"] = round(time.monotonic() - started, 2)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["json", "sse", "both"], default="both")
    args = parser.parse_args()
    base_url = os.environ.get("WOOW_MODEL_TEST_BASE_URL", "")
    model = os.environ.get("WOOW_MODEL_TEST_MODEL", "")
    key = os.environ.get("WOOW_MODEL_TEST_API_KEY") or getpass.getpass("Model test API key (hidden): ")
    if not base_url or not model or not key:
        print(json.dumps({"passed": False, "error": "missing_configuration"}))
        sys.exit(1)
    results = [probe(stream, base_url, model, key) for stream in
               ([False, True] if args.mode == "both" else [args.mode == "sse"])]
    for result in results:
        print(json.dumps(result))
    sys.exit(0 if all(result["passed"] for result in results) else 1)
