import subprocess, urllib.request, json, sys
sys.stdout.reconfigure(encoding="utf-8")
out = subprocess.run(['git','credential','fill'], input='protocol=https\nhost=github.com\n', capture_output=True, text=True).stdout
tok = [l.split('=',1)[1] for l in out.splitlines() if l.startswith('password=')][0]
hdr = {'Authorization': f'token {tok}', 'User-Agent': 'myfood', 'Accept': 'application/vnd.github+json'}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

opener = urllib.request.build_opener(NoRedirect)
req = urllib.request.Request('https://api.github.com/repos/Tokeiyo929/myfood-ios/actions/jobs/122576107540/logs', headers=hdr)
try:
    resp = opener.open(req)
    log = resp.read().decode('utf-8','replace')
except urllib.error.HTTPError as e:
    if e.code in (301, 302, 303, 307):
        url = e.headers['Location']
        # re-sign? The redirect requires no auth typically
        log = urllib.request.urlopen(url, timeout=60).read().decode('utf-8','replace')
    else:
        raise
lines = log.splitlines()
shown = 0
for i,l in enumerate(lines):
    if 'error:' in l.lower() and shown < 10:
        print('\n'.join(lines[max(0,i-1):i+4])); print('---'); shown += 1
if not shown:
    print('\n'.join(lines[-40:]))
