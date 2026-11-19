import json
import os
import time
import urllib.error
import urllib.request

TOKEN = os.environ["GITHUB_TOKEN"]
OWNER = "Nishsh"
REPO = "navnative"
API = "https://api.github.com"


def call(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("User-Agent", "wb")
    req.add_header("Accept", "application/vnd.github+json")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            p = r.read()
            return r.status, (json.loads(p) if p else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400].decode("utf-8", "replace")


def main():
    status, _ = call("POST", "/repos/%s/%s/actions/workflows/build-ipa.yml/dispatches" % (OWNER, REPO), {"ref": "main"})
    print("dispatch ->", status, flush=True)

    run = None
    deadline = time.time() + 25 * 60
    while time.time() < deadline:
        time.sleep(20)
        s, d = call("GET", "/repos/%s/%s/actions/runs?per_page=5" % (OWNER, REPO))
        if s != 200 or not d.get("workflow_runs"):
            continue
        cand = d["workflow_runs"][0]
        run = cand
        print("  run %s %s/%s" % (cand["id"], cand["status"], cand["conclusion"]), flush=True)
        if cand["status"] == "completed":
            break

    if not run:
        print("未找到构建记录", flush=True)
        return

    if run.get("conclusion") != "success":
        s, jobs = call("GET", "/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, run["id"]))
        for j in jobs.get("jobs", []):
            print("JOB", j["id"], j["name"], j["conclusion"], flush=True)
            for st in j.get("steps", []):
                print("   ", st["number"], st["name"], st["conclusion"], flush=True)
        print("RUN_ID", run["id"], flush=True)
        return

    s, arts = call("GET", "/repos/%s/%s/actions/runs/%s/artifacts" % (OWNER, REPO, run["id"]))
    if s != 200 or not arts.get("artifacts"):
        print("未找到产物", flush=True)
        return

    art = arts["artifacts"][0]
    url = "%s/repos/%s/%s/actions/artifacts/%s/zip" % (API, OWNER, REPO, art["id"])
    os.makedirs("dist", exist_ok=True)
    out = os.path.join("dist", art["name"] + ".zip")

    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("User-Agent", "wb")
    opener = urllib.request.build_opener(urllib.request.HTTPRedirectHandler())
    with opener.open(req, timeout=180) as resp, open(out, "wb") as fh:
        fh.write(resp.read())
    print("ARTIFACT", out, os.path.getsize(out), flush=True)


main()
