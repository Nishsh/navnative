#!/usr/bin/env python3
"""轮询最新一次 Actions 运行，直到完成；失败时把错误行抓出来。

用法：
    GITHUB_TOKEN=xxx python tools/poll_build.py [--minutes 25]

只依赖标准库。代理通过环境变量 https_proxy 生效。
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

TOKEN = os.environ.get("GITHUB_TOKEN", "")
OWNER = "Nishsh"
REPO = "navnative"
API = "https://api.github.com"


def call(path, retries=5):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("User-Agent", "wb-poll")
    req.add_header("Accept", "application/vnd.github+json")
    last = None
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as exc:
            return {"__error__": exc.code, "body": exc.read()[:300].decode("utf-8", "replace")}
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(3)
    print("api 不通:", last)
    return {}


def log_tail(job_id, patterns, limit=40):
    req = urllib.request.Request(f"{API}/repos/{OWNER}/{REPO}/actions/jobs/{job_id}/logs")
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("User-Agent", "wb-poll")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            text = resp.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        print("取日志失败:", exc)
        return
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    hits = [line for line in text.splitlines() if any(p in line for p in patterns)]
    for line in hits[:limit]:
        print("   ", line.strip()[:220])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--minutes", type=float, default=25)
    args = parser.parse_args()

    deadline = time.time() + args.minutes * 60
    last_state = None
    while time.time() < deadline:
        data = call(f"/repos/{OWNER}/{REPO}/actions/runs?per_page=1")
        runs = data.get("workflow_runs") or []
        if not runs:
            print("没有找到运行记录")
            return 1
        run = runs[0]
        state = (run["status"], run["conclusion"])
        if state != last_state:
            print(f"[{time.strftime('%H:%M:%S')}] run {run['id']} -> {run['status']} / {run['conclusion']}", flush=True)
            last_state = state

        if run["status"] == "completed":
            jobs = call(f"/repos/{OWNER}/{REPO}/actions/runs/{run['id']}/jobs")
            job_list = jobs.get("jobs", [])
            for job in job_list:
                print("JOB", job["id"], job["name"], job["conclusion"])
                for step in job.get("steps", []):
                    print("   ", step["number"], step["name"], step["status"], step["conclusion"])
            if run["conclusion"] == "success":
                arts = call(f"/repos/{OWNER}/{REPO}/actions/runs/{run['id']}/artifacts")
                for art in arts.get("artifacts", []):
                    print("ARTIFACT", art["id"], art["name"], art["size_in_bytes"])
                return 0
            patterns = ("error:", "warning: ", "FAILED", "Command failed", "The following build commands failed")
            for job in job_list:
                if job["conclusion"] != "success":
                    print("--- 错误日志 ---")
                    log_tail(job["id"], patterns)
            return 2
        time.sleep(12)

    print("等待超时")
    return 3


if __name__ == "__main__":
    sys.exit(main())
