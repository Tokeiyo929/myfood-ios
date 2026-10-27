import subprocess, urllib.request, urllib.error, sys
sys.stdout.reconfigure(encoding="utf-8")
cred = subprocess.run(["git","credential","fill"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True).stdout
tok = [l.split("=",1)[1] for l in cred.splitlines() if l.startswith("password=")][0]
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
opener = urllib.request.build_opener(NoRedirect)
# job id of latest failed run
import json
req = urllib.request.Request("https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs/40438952648/jobs", headers={"Authorization":"token "+tok,"User-Agent":"x"})
jobs = json.loads(urllib.request.urlopen(req).read())["jobs"]
jid = jobs[0]["id"]
req = urllib.request.Request("https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/%s/logs" % jid, headers={"Authorization":"token "+tok,"User-Agent":"x"})
try: opener.open(req)
except urllib.error.HTTPError as e:
    loc = e.headers.get("Location")
    data = urllib.request.urlopen(urllib.request.Request(loc, headers={"User-Agent":"x"})).read().decode("utf-8","replace")
    lines = [l for l in data.splitlines() if any(k in l for k in ("npm error","[error]","cap sync","Error","✖","√ @capacitor","Error:"))]
    print("\n".join(lines[:40]))
