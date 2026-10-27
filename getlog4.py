import subprocess, urllib.request, urllib.error, sys, json
sys.stdout.reconfigure(encoding="utf-8")
cred = subprocess.run(["git","credential","fill"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True).stdout
tok = [l.split("=",1)[1] for l in cred.splitlines() if l.startswith("password=")][0]
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
opener = urllib.request.build_opener(NoRedirect)
req = urllib.request.Request("https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/122175699620/logs", headers={"Authorization":"token "+tok,"User-Agent":"x"})
try: opener.open(req)
except urllib.error.HTTPError as e:
    loc = e.headers.get("Location")
    data = urllib.request.urlopen(urllib.request.Request(loc, headers={"User-Agent":"x"})).read().decode("utf-8","replace")
    open(r"D:/GitHub/MyFood/myfood-ios/joblog2.txt","w",encoding="utf-8").write(data)
    # find the sync section
    idx = data.find("cap sync")
    print(data[idx:idx+3000] if idx>=0 else data[-3000:])
