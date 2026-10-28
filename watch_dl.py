import subprocess, urllib.request, json, sys, os, zipfile, time
sys.stdout.reconfigure(encoding="utf-8")
os.chdir(r"D:/GitHub/MyFood/myfood-ios")

def token():
    out = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n", capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("no token")

tok = token()
hdr = {"Authorization": f"token {tok}", "User-Agent": "myfood"}
# find run for commit 2de7360
sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
for attempt in range(20):
    req = urllib.request.Request(f"https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs?head_sha={sha}", headers=hdr)
    runs = json.load(urllib.request.urlopen(req))
    if runs["workflow_runs"]:
        run = runs["workflow_runs"][0]
        break
    time.sleep(15)
else:
    raise SystemExit("no run found")
print("run", run["id"], run["status"])
rid = run["id"]
for attempt in range(120):
    req = urllib.request.Request(f"https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs/{rid}", headers=hdr)
    r = json.load(urllib.request.urlopen(req))
    print("status:", r["status"], r["conclusion"], flush=True)
    if r["status"] == "completed":
        break
    time.sleep(15)
if r["conclusion"] != "success":
    # fetch failed job log tail
    req = urllib.request.Request(f"https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs/{rid}/jobs", headers=hdr)
    jobs = json.load(urllib.request.urlopen(req))
    for j in jobs["jobs"]:
        if j["conclusion"] != "success":
            req2 = urllib.request.Request(j["url"], headers=hdr)
            # get log via steps? use log endpoint
            try:
                req3 = urllib.request.Request(f"{j['url']}/logs", headers=hdr)
                log = urllib.request.urlopen(req3).read().decode("utf-8", "replace")
                print(log[-4000:])
            except Exception as e:
                print("log fetch failed:", e)
    sys.exit(1)
# download artifact
req = urllib.request.Request(f"https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs/{rid}/artifacts", headers=hdr)
arts = json.load(urllib.request.urlopen(req))
a = arts["artifacts"][0]
dl = urllib.request.Request(a["archive_download_url"], headers=hdr)
zp = urllib.request.urlopen(dl).read()
open(r"C:/Users/tuangyu/Desktop/myfood-unsigned.ipa.zip", "wb").write(zp)
with zipfile.ZipFile(r"C:/Users/tuangyu/Desktop/myfood-unsigned.ipa.zip") as z:
    z.extractall(r"C:/Users/tuangyu/Desktop/_myfood_ipa")
os.remove(r"C:/Users/tuangyu/Desktop/myfood-unsigned.ipa.zip")
# move ipa
import shutil
src = r"C:/Users/tuangyu/Desktop/_myfood_ipa/myfood-unsigned.ipa"
dst = r"C:/Users/tuangyu/Desktop/myfood-unsigned.ipa"
if os.path.exists(dst): os.remove(dst)
shutil.move(src, dst)
shutil.rmtree(r"C:/Users/tuangyu/Desktop/_myfood_ipa", ignore_errors=True)
print("OK ipa at Desktop, size", os.path.getsize(dst))
