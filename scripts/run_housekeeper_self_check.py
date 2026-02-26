#!/usr/bin/env python3
"""Run built-in Housekeeper loop self-checks via runtime endpoint."""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run /housekeeper/self-check and fail on guard regressions.")
    parser.add_argument("--endpoint", default="http://127.0.0.1:48765", help="Runtime base URL.")
    parser.add_argument("--token", default="", help="Bearer token, defaults to BLAB_HOUSEKEEPER_TOKEN.")
    parser.add_argument("--health-retries", type=int, default=3, help="Health-check retries before self-check.")
    parser.add_argument("--health-timeout", type=float, default=2.0, help="Per health-check timeout (seconds).")
    parser.add_argument("--retry-delay", type=float, default=0.7, help="Delay between health retries (seconds).")
    return parser.parse_args()


def request_json(method: str, url: str, headers: Optional[Dict[str, str]] = None, timeout: float = 10.0) -> Tuple[int, str]:
    request = urllib.request.Request(url=url, method=method)
    for key, value in (headers or {}).items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            return response.status, raw
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        return error.code, raw


def parse_json_or_none(raw: str) -> Optional[Dict[str, Any]]:
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None


def ensure_health(base_url: str, retries: int, timeout: float, delay: float, headers: Dict[str, str]) -> None:
    url = f"{base_url}/housekeeper/health"
    for attempt in range(1, retries + 1):
        status, raw = request_json("GET", url, headers=headers, timeout=timeout)
        body = parse_json_or_none(raw)
        if status == 200 and body and body.get("ok") is True:
            return
        if attempt < retries:
            time.sleep(delay)

    print("health check failed: runtime not ready", file=sys.stderr)
    sys.exit(10)


def main() -> None:
    args = parse_args()
    base_url = args.endpoint.rstrip("/")
    token = args.token or os.environ.get("BLAB_HOUSEKEEPER_TOKEN", "")

    headers: Dict[str, str] = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    ensure_health(base_url, args.health_retries, args.health_timeout, args.retry_delay, headers)

    status, raw = request_json("GET", f"{base_url}/housekeeper/self-check", headers=headers, timeout=20.0)
    body = parse_json_or_none(raw)

    if body is None:
        print(raw)
        print("self-check response is not valid JSON", file=sys.stderr)
        sys.exit(20)

    print(json.dumps(body, ensure_ascii=False, indent=2))

    if status >= 400:
        print(f"self-check endpoint returned HTTP {status}", file=sys.stderr)
        sys.exit(20)

    if body.get("ok") is True:
        sys.exit(0)

    checks = body.get("checks")
    if isinstance(checks, list):
        failed = [c for c in checks if isinstance(c, dict) and c.get("passed") is not True]
        for item in failed:
            name = str(item.get("name") or "unknown")
            detail = str(item.get("detail") or "")
            print(f"[FAILED] {name}: {detail}", file=sys.stderr)

    sys.exit(1)


if __name__ == "__main__":
    main()
