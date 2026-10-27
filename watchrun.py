import subprocess, urllib.request, time, sys
sys.stdout.reconfigure(encoding="utf-8")
cred = subprocess.run(["git","credential","fill"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True).stdout
tok = [l.split("=",1)[1] for l in cred.splitlines() if l.startswith("password=")][0]

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
opener = urllib.request.build_opener(NoRedirect)

def api(url):
    req = urllib.request.Request(url, headers={"Authorization":"token "+tok,"User-Agent":"x"})
    return json.loads(urllib.request.urlopen(req).read())

import json
run = api("https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs?per_page=1")["workflow_runs"][0]
print("run", run["id"], run["status"])
# poll until completed (max ~8 min)
for i in range(48):
    if run["status"] == "completed":
        break
    time.sleep(10)
    run = api("https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs?per_page=1")["workflow_runs"][0]
    if i % 6 == 0: print("...", run["status"])
print("RESULT:", run["conclusion"], run["html_url"])
if run["conclusion"] == "failure":
    jobs = api(run["jobs_url"])["jobs"]
    for j in jobs:
        for s in j["steps"]:
            if s["conclusion"] == "failure":
                print("failed step:", s["name"])
                # fetch logs
                req = urllib.request.Request("https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/%s/logs" % j["id"], headers={"Authorization":"token "+tok,"User-Agent":"x"})
                try:
                    opener.open(req)
                except urllib.error.HTTPError as e:
                    loc = e.headers.get("Location")
                    data = urllib.request.urlopen(urllib.request.Request(loc, headers={"User-Agent":"x"})).read().decode("utf-8","replace")
                    err = [l for l in data.splitlines() if "##[error]" in l or "error:" in l.lower()][:25]
                    print("\n".join(err))
else:
    arts = api(run["artifacts_url"])["artifacts"]
    for a in arts: print("artifact:", a["name"], a["size_in_bytes"], "bytes", a["archive_download_url"])
