#!/usr/bin/env python3
"""显式指定测试后端；创建临时记录，并在 finally 中等待删除完成。"""
import argparse
import json
import sys
import urllib.error
import urllib.request
from uuid import uuid4


def run(base, proxy=None):
    proxies = None if proxy is None else {} if proxy.lower() == "none" else {"http": proxy, "https": proxy}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies))
    failures = []

    def check(name, ok, detail=""):
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f" {detail}" if not ok else ""))
        if not ok:
            failures.append(name)

    def call(method, path, body=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(base.rstrip("/") + path, data=data, method=method,
                                         headers={"User-Agent": "MyFood-RegressionTest/1.0", "Content-Type": "application/json; charset=utf-8"})
        try:
            with opener.open(request, timeout=30) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, {"error": error.read().decode("utf-8", "replace")}

    food_id = None
    try:
        name = "测试·泡芙蛋糕"
        comments = ["奶油挺多的，味道不错！", "中文 UTF-8 roundtrip 🍰"]
        status, created = call("POST", "/api/foods", {
            "name": name, "brand_name": "测试品牌", "price": [12.5, None],
            "categories": [], "ingredients": [], "flavors": [], "preference": "推荐吃",
            "worth_it": True, "freshness": "短保", "comment": comments, "image_path": "",
            "image_metadata": {}, "client_key": "autotest-" + uuid4().hex,
        })
        food_id = created.get("id")
        check("POST 中文新增", status == 200 and isinstance(food_id, int), str(created))
        if isinstance(food_id, int):
            path = f"/api/foods/{food_id}"
            status, food = call("GET", path)
            check("GET 中文/worth_it/freshness", status == 200 and food.get("name") == name
                  and food.get("comment") == comments and food.get("worth_it") == "yes"
                  and food.get("freshness") == "短保", str(food))
            comments += ["追加的一条评论"]
            status, _ = call("PATCH", path, {"comment": comments})
            read_status, food = call("GET", path)
            check("PATCH 中文评论", status == 200 and read_status == 200 and food.get("comment") == comments)
            status, _ = call("PATCH", path, {"fields": {"name": "改名·草莓大福", "price": [18, 9.9], "worth_it": False, "freshness": "长保"}})
            read_status, food = call("GET", path)
            check("PATCH 名称/价格/worth_it/freshness", status == 200 and read_status == 200
                  and food.get("name") == "改名·草莓大福" and food.get("worth_it") == "no"
                  and food.get("price") == [18, 9.9] and food.get("freshness") == "长保")
            status, _ = call("PATCH", path, {"fields": {"freshness": ""}})
            read_status, food = call("GET", path)
            check("清空新鲜度", status == 200 and read_status == 200 and food.get("freshness") == "")
            status, _ = call("PATCH", path, {"fields": {"preference": 60}})
            check("非法偏好拒绝", status == 400)
            status, _ = call("PATCH", path, {"fields": {"freshness": "隔夜"}})
            check("非法新鲜度拒绝", status == 400)
        status, _ = call("GET", "/api/tracks/days")
        check("轨迹日期可达", status == 200)
    except Exception as error:
        check("请求异常", False, str(error))
    finally:
        if isinstance(food_id, int):
            try:
                status, _ = call("DELETE", f"/api/foods/{food_id}")
                check("删除临时记录", status == 200, f"id={food_id}, HTTP {status}")
            except Exception as error:
                check("删除临时记录", False, f"id={food_id}: {error}")
    print("RESULT: FAIL" if failures else "RESULT: ALL PASS")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_url", help="测试服务地址（会写入临时记录）")
    parser.add_argument("--proxy", help="代理 URL；none 为直连；省略使用系统代理")
    args = parser.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    return run(args.base_url, args.proxy)


if __name__ == "__main__":
    sys.exit(main())
