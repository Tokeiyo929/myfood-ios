import subprocess, os, sys
sys.stdout.reconfigure(encoding="utf-8")
os.chdir(r"D:/GitHub/MyFood/myfood-ios")

# get token via git credential
cred = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                      capture_output=True, text=True).stdout
tok = [l.split("=",1)[1] for l in cred.splitlines() if l.startswith("password=")][0]

# logs endpoint 302-redirects to a signed URL; requests in python handles cookies/redirects
import urllib.request
req = urllib.request.Request(
    "https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/121970285639/logs",
    headers={"Authorization": "Bearer " + tok, "User-Agent": "myfood"})
with urllib.request.urlopen(req) as r:
    data = r.read().decode("utf-8", "replace")
open("joblog.txt", "w", encoding="utf-8").write(data)
lines = data.splitlines()
print("\n".join(lines[-45:]))
