"""覆盖全部 23 个 MCP 工具端点的冒烟测试。"""
import sys

import httpx

BASE = "http://localhost:8081"
OK, FAIL = [], []


def check(label, resp, *, expect_code=200, probe=None):
    try:
        body = resp.json()
    except Exception as exc:
        FAIL.append(f"{label}: 响应非 JSON ({exc}) — {resp.text[:120]}")
        return None
    code = body.get("code")
    ok = resp.status_code == 200 and code == expect_code
    detail = ""
    if ok and probe:
        try:
            detail = probe(body.get("data"))
        except Exception as exc:
            ok, detail = False, f"probe 失败: {exc}"
    (OK if ok else FAIL).append(
        f"{label}: code={code} http={resp.status_code}{' ' + detail if detail else ''}"
        if ok else
        f"{label}: 期望 code={expect_code} 实际 code={code} http={resp.status_code} — {str(body)[:150]}"
    )
    return body


with httpx.Client(base_url=BASE, timeout=15.0) as c:
    # ---------- 供应商 5 ----------
    check("supplier_query", c.get("/api/suppliers/search", params={"name": "博世"}),
          probe=lambda d: f"命中 {len(d)} 条")
    check("supplier_page", c.get("/api/suppliers/page", params={"current": 1, "size": 5}),
          probe=lambda d: f"total={d['total']} pages={d['pages']} records={len(d['records'])}")
    check("supplier_page(筛选)", c.get("/api/suppliers/page",
          params={"status": 1, "creditRating": "A"}),
          probe=lambda d: f"A级合作中 {d['total']} 家")
    check("supplier_get", c.get("/api/suppliers/get/1"),
          probe=lambda d: d["name"])
    check("supplier_get(404)", c.get("/api/suppliers/get/9999"), expect_code=404)
    check("supplier_create", c.post("/api/suppliers/create", json={
        "supplierCode": "SUP9001", "name": "测试供应商", "contactPerson": "测试",
        "creditRating": "B", "status": 1}), probe=lambda d: f"id={d['id']}")
    check("supplier_update_status", c.patch("/api/suppliers/update-status/1",
          params={"status": 0}), probe=lambda d: f"status={d['status']}")

    # ---------- 零部件 5 ----------
    check("part_search", c.get("/api/parts/search", params={"name": "火花塞"}),
          probe=lambda d: f"命中 {len(d)} 条")
    check("part_query", c.get("/api/parts/get/1"),
          probe=lambda d: f"{d['name']} 采购价={d['purchasePrice']} 供应商={d['supplierName']}")
    check("part_by_supplier", c.get("/api/parts/supplier/1"),
          probe=lambda d: f"{len(d)} 个零件")
    check("part_page", c.get("/api/parts/page", params={"current": 1, "size": 5}),
          probe=lambda d: f"total={d['total']}")
    check("part_page(按分类)", c.get("/api/parts/page", params={"category": "制动系统"}),
          probe=lambda d: f"制动系统 {d['total']} 个")
    check("part_create", c.post("/api/parts/create", json={
        "partCode": "P-TEST-999", "name": "测试零件", "purchasePrice": 99.5,
        "supplierId": 1, "category": "发动机系统", "stockWarningValue": 10}),
        probe=lambda d: f"id={d['id']}")

    # ---------- 订单 7 ----------
    check("order_create", c.post("/api/orders/create", json={
        "orderNumber": "PO-TEST-001", "status": 0, "remark": "冒烟测试",
        "orderDetail": [{"partId": 1, "quantity": 100, "unitPrice": 25.5},
                        {"partId": 7, "quantity": 50, "unitPrice": 28.0}]}),
        probe=lambda d: f"id={d['id']} totalAmount={d['totalAmount']} 明细={len(d['orderDetail'])}")
    check("order_create(校验)", c.post("/api/orders/create", json={
        "orderDetail": [{"partId": 99999, "quantity": 1, "unitPrice": 1}]}), expect_code=404)
    check("order_page", c.get("/api/orders/page", params={"current": 1, "size": 5}),
          probe=lambda d: f"total={d['total']}")
    check("order_page(按状态)", c.get("/api/orders/page", params={"status": 4}),
          probe=lambda d: f"已完成 {d['total']} 单")
    check("order_page(按日期)", c.get("/api/orders/page",
          params={"startDate": "2020-01-01", "endDate": "2030-01-01"}),
          probe=lambda d: f"区间内 {d['total']} 单")
    check("order_get", c.get("/api/orders/get/1"),
          probe=lambda d: f"{d['orderNumber']} 明细={len(d['orderDetail'])} 首行子项={d['orderDetail'][0]['subtotal']}")
    check("order_search_details", c.get("/api/orders/search-details",
          params={"partName": "火花塞"}),
          probe=lambda d: f"{len(d)} 条明细, 首条供应商={d[0]['supplierName'] if d else 'N/A'}")
    check("order_statistics", c.get("/api/orders/statistics"),
          probe=lambda d: f"{d['totalOrders']} 单 总额={d['totalAmount']} 状态数={len(d['byStatus'])}")
    check("order_statistics(区间)", c.get("/api/orders/statistics",
          params={"startDate": "2020-01-01", "endDate": "2030-01-01"}),
          probe=lambda d: f"{d['totalOrders']} 单")
    check("order_update_status", c.patch("/api/orders/update-status/2",
          params={"status": 1}), probe=lambda d: f"status={d['status']}")
    check("order_update", c.put("/api/orders/update/2", json={"remark": "更新测试"}),
          probe=lambda d: f"remark={d['remark']}")

    # ---------- 库存 6 ----------
    check("inventory_warning", c.get("/api/inventory/warning"),
          probe=lambda d: f"{len(d)} 条预警, 首条={d[0]['partDetail']['name'] if d else 'N/A'}")
    check("inventory_page", c.get("/api/inventory/page", params={"current": 1, "size": 5}),
          probe=lambda d: f"total={d['total']} 首条有 partDetail={'partDetail' in d['records'][0]}")
    check("inventory_check", c.get("/api/inventory/check"),
          probe=lambda d: f"SKU={d['totalSku']} 预警={d['warningCount']} 总值={d['totalValue']}")
    check("inventory_get", c.get("/api/inventory/get/1"),
          probe=lambda d: f"库存={d['currentQuantity']}")
    check("inventory_inbound", c.post("/api/inventory/inbound",
          params={"partId": 1, "quantity": 50, "warehouseLocation": "A区-01-01"}),
        probe=lambda d: f"入库后={d['currentQuantity']}")
    check("inventory_outbound", c.post("/api/inventory/outbound",
          params={"partId": 1, "quantity": 20}), probe=lambda d: f"出库后={d['currentQuantity']}")
    check("inventory_outbound(库存不足)", c.post("/api/inventory/outbound",
          params={"partId": 1, "quantity": 999999}), expect_code=400)

print(f"\n{'='*64}\n通过 {len(OK)} / {len(OK)+len(FAIL)}\n{'='*64}")
for line in OK:
    print(f"  OK   {line}")
if FAIL:
    print()
    for line in FAIL:
        print(f"  FAIL {line}")
    sys.exit(1)
