#!/usr/bin/env python3
"""MyFood 后端 API 回归测试（纯 UTF-8 客户端）。

用法:
  python -I backend_api_test.py [BASE_URL] [PROXY]
  BASE_URL 默认 https://myfood.tuqingyu.xyz
  PROXY    例 http://127.0.0.1:7897；传 none 则直连

覆盖: 中文读写 charset、评论 PATCH、worth_it 往返、价格、新增/删除记录。
全部走临时 client_key 数据，跑完自动清理，不污染正式数据。
"""
import json
import sys
import time
import urllib.request
import urllib.error

sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows 控制台 cp1252 兼容

BASE = sys.argv[1] if len(sys.argv) > 1 else "https://myfood.tuqingyu.xyz"
PROXY = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:7897"
if PROXY.lower() == "none":
    PROXY = None

OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": PROXY, "https": PROXY} if PROXY else {})
)

CLIENT_KEY = "autotest-%d" % int(time.time() * 1000)
FAILURES = []


def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("User-Agent", "MyFood-RegressionTest/1.0")  # 无 UA 会被 Cloudflare 1010 拦
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")  # 干净 UTF-8
        req.add_header("Content-Type", "application/json; charset=utf-8")
    try:
        resp = OPENER.open(req, data=data, timeout=30)
        return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw}


def check(name, ok, detail=""):
    tag = "PASS" if ok else "FAIL"
    print(f"[{tag}] {name}" + (f"  {detail}" if detail and not ok else ""))
    if not ok:
        FAILURES.append(name)


# 1. 新增（中文 + 完整字段）
name0 = "测试·泡芙蛋糕"
comment0 = ["奶油挺多的，味道不错！", "中文 UTF-8 roundtrip 🍰"]
status, r = call("POST", "/api/foods", {
    "name": name0, "brand_name": "测试品牌", "price": [12.5, None],
    "categories": ["测试类目"], "ingredients": [{"name": "奶油", "amount": None}],
    "flavors": [{"name": "甜", "level": 4}], "preference": "推荐吃",
    "worth_it": True, "comment": comment0, "image_path": "",
    "image_metadata": {}, "client_key": CLIENT_KEY,
})
check("POST /api/foods 中文新增", status == 200 and r.get("id"), f"status={status} body={r}")
fid = r.get("id")

if fid:
    # 2. 读回验证 charset
    status, g = call("GET", f"/api/foods/{fid}")
    check("GET 读回 name 中文不变", g.get("name") == name0, f"got={g.get('name')!r}")
    check("GET 读回 comment 中文不变", g.get("comment") == comment0, f"got={g.get('comment')!r}")
    check("GET 读回 worth_it=yes", g.get("worth_it") == "yes", f"got={g.get('worth_it')!r}")

    # 3. PATCH 评论（中文）→ 读回
    comment1 = comment0 + ["追加的一条评论"]
    status, r = call("PATCH", f"/api/foods/{fid}", {"comment": comment1})
    status2, g = call("GET", f"/api/foods/{fid}")
    check("PATCH comment 中文往返", status == 200 and status2 == 200 and g.get("comment") == comment1,
          f"patch={status} got={g.get('comment')!r}")

    # 4. PATCH fields（中文名 + 价格 + worth_it false）
    status, r = call("PATCH", f"/api/foods/{fid}", {
        "fields": {"name": "改名·草莓大福", "price": [18, 9.9], "worth_it": False}})
    status2, g = call("GET", f"/api/foods/{fid}")
    check("PATCH fields 中文/价格/worth_it",
          status == 200 and g.get("name") == "改名·草莓大福" and g.get("worth_it") == "no"
          and g.get("price") == [18, 9.9],
          f"patch={status} name={g.get('name')!r} worth={g.get('worth_it')!r} price={g.get('price')!r}")

    # 5. 非法偏好应被拒
    status, r = call("PATCH", f"/api/foods/{fid}", {"fields": {"preference": 60}})
    check("PATCH preference=60 被拒(400)", status == 400, f"status={status}")

    # 6. 清理
    status, r = call("DELETE", f"/api/foods/{fid}")
    check("DELETE 清理测试记录", status == 200, f"status={status}")

# 7. tracks days 接口可达
status, r = call("GET", "/api/tracks/days")
check("GET /api/tracks/days 可达", status == 200, f"status={status}")

print()
if FAILURES:
    print(f"RESULT: FAIL ({len(FAILURES)}): {'; '.join(FAILURES)}")
    sys.exit(1)
print("RESULT: ALL PASS")
