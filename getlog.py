import subprocess, urllib.request, json, sys
sys.stdout.reconfigure(encoding="utf-8")
out = subprocess.run(['git','credential','fill'], input='protocol=https\nhost=github.com\n', capture_output=True, text=True).stdout
tok = [l.split('=',1)[1] for l in out.splitlines() if l.startswith('password=')][0]
hdr = {'Authorization': f'token {tok}', 'User-Agent': 'myfood'}
sha = subprocess.run(['git','rev-parse','HEAD'], capture_output=True, text=True).stdout.strip()
req = urllib.request.Request(f'https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs?head_sha={sha}', headers=hdr)
run = json.load(urllib.request.urlopen(req))['workflow_runs'][0]
print('run', run['id'], run['conclusion'])
req = urllib.request.Request(f'https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/runs/{run["id"]}/jobs', headers=hdr)
jobs = json.load(urllib.request.urlopen(req))
jid = jobs['jobs'][0]['id']

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)
req = urllib.request.Request(f'https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/{jid}/logs', headers=hdr)
try:
    log = opener.open(req).read().decode('utf-8','replace')
except urllib.error.HTTPError as e:
    log = urllib.request.urlopen(e.headers['Location'], timeout=60).read().decode('utf-8','replace')
lines = log.splitlines()
shown = 0
for i,l in enumerate(lines):
    if 'error:' in l.lower() and shown < 10:
        print('\n'.join(lines[max(0,i-1):i+3])); print('---'); shown += 1
if not shown:
    print('\n'.join(lines[-30:]))
