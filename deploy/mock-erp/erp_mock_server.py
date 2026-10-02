"""
Mock ERP 后端服务 —— 为 Agent-Harness 提供供应链数据

背景：开源仓库只包含 Agent 侧，MCP 的 23 个工具全部指向一个外部 ERP 服务
（默认 http://localhost:8081），该服务未开源。本文件实现它，让全链路可跑通。

实现 src/mcp_server/tools/ 下 4 个模块声明的全部 23 个端点。
响应统一信封 {"code": 200, "message": "success", "data": ...}，
与 http_base.py 错误分支的 {code, message, data} 形状保持一致。

数据为内存态、进程重启即重置；种子数据固定（random.Random(42)），
日期锚定在启动当天，保证可复现。

启动：python erp_mock_server.py   （监听 0.0.0.0:8081）
"""
from __future__ import annotations

import random
from datetime import datetime, timedelta
from typing import Any, Optional

import uvicorn
from fastapi import Body, FastAPI, Query
from fastapi.responses import JSONResponse

# ============================================================
# 响应信封
# ============================================================

def ok(data: Any = None, message: str = "success") -> dict:
    return {"code": 200, "message": message, "data": data}


def fail(message: str, code: int = 400, data: Any = None) -> JSONResponse:
    return JSONResponse(
        status_code=200 if code < 500 else code,
        content={"code": code, "message": message, "data": data},
    )


# ============================================================
# 内存数据层
# ============================================================

class Store:
    def __init__(self) -> None:
        self.suppliers: list[dict] = []
        self.parts: list[dict] = []
        self.orders: list[dict] = []
        self.order_details: list[dict] = []
        self.inventory: list[dict] = []
        self._seq = {"supplier": 0, "part": 0, "order": 0, "detail": 0, "inventory": 0}

    def next_id(self, kind: str) -> int:
        self._seq[kind] += 1
        return self._seq[kind]


store = Store()
NOW = datetime.now()

# 供应商：名称 / 联系人 / 电话 / 邮箱 / 地址 / 信用评级 / 合作状态
_SUPPLIER_SEED = [
    ("华胜机械制造有限公司", "张伟", "0571-88123401", "sales@huasheng-mach.com", "浙江省杭州市萧山区工业园12号", "A", 1),
    ("恒达汽车配件有限公司", "李娜", "0512-67891202", "contact@hengda-parts.com", "江苏省苏州市吴中区经济开发区8号", "A", 1),
    ("博世汽车部件（苏州）有限公司", "王强", "0512-88123403", "info@bosch-sz.com", "江苏省苏州市工业园区星海街158号", "A", 1),
    ("电装（中国）投资有限公司", "陈静", "021-58761204", "service@denso-cn.com", "上海市浦东新区金桥出口加工区18号", "A", 1),
    ("NGK火花塞（上海）有限公司", "刘洋", "021-64321205", "sales@ngk-sh.com", "上海市闵行区莘庄工业区76号", "B", 1),
    ("隆鑫通用动力股份有限公司", "赵磊", "023-67891206", "purchase@loncin.com", "重庆市九龙坡区隆鑫工业园", "B", 1),
    ("宗申动力机械股份有限公司", "孙丽", "023-56781207", "sales@zongshen.com", "重庆市巴南区宗申工业园", "B", 1),
    ("春风动力股份有限公司", "周涛", "0571-88991208", "contact@cfmoto.com", "浙江省杭州市余杭区春风路1号", "B", 1),
    ("捷安特轻合金科技有限公司", "吴敏", "0512-34561209", "sales@giant-alloy.com", "江苏省昆山市开发区前进东路", "C", 1),
    ("万向钱潮股份有限公司", "郑峰", "0571-22341210", "info@wanxiang.com", "浙江省杭州市萧山区万向路1号", "C", 1),
    ("钱江摩托配件厂", "冯建国", "0576-88121211", "qianjiang@parts.com", "浙江省台州市温岭市工业路", "C", 1),
    ("新大洲本田摩托有限公司", "许燕", "021-51231212", "sundiro@honda-cn.com", "上海市嘉定区新大洲工业园", "D", 0),
    ("力帆实业集团配件公司", "何军", "023-88991213", "lifan@parts.com", "重庆市北碚区力帆工业园", "D", 0),
    ("银钢科技集团供应商", "罗红", "023-66781214", "yingang@parts.com", "重庆市璧山区银钢工业园", "D", 0),
]

# 零部件：编码 / 名称 / 型号 / 规格 / 单位 / 采购价 / 建议零售价 / 预警值 / 分类 / 描述
_PART_SEED = [
    ("P-EN-0001", "火花塞", "NGK-CR8EIX", "M10x1.0 铱金", "个", 25.50, 45.00, 200, "发动机系统", "铱金电极火花塞，适配125-250cc单缸发动机"),
    ("P-EN-0002", "活塞环", "PR-56.5", "56.5mm 标准环", "套", 38.00, 68.00, 150, "发动机系统", "高碳铸铁活塞环组"),
    ("P-EN-0003", "气缸垫", "CG-150", "150cc 石棉复合", "片", 12.80, 24.00, 300, "发动机系统", "耐高温气缸密封垫片"),
    ("P-EN-0004", "曲轴总成", "CS-200", "200cc 锻造", "套", 385.00, 620.00, 40, "发动机系统", "整体锻造曲轴，含连杆轴承"),
    ("P-EN-0005", "气门油封", "VS-12", "12mm 氟橡胶", "个", 3.20, 8.00, 800, "发动机系统", "耐高温氟橡胶气门杆油封"),
    ("P-EN-0006", "正时链条", "TC-92L", "92节 滚子链", "条", 56.00, 98.00, 120, "发动机系统", "高强度正时传动链"),
    ("P-BR-0001", "前刹车片", "BP-F125", "125cc 半金属", "套", 28.00, 58.00, 250, "制动系统", "半金属配方前刹片，低粉尘"),
    ("P-BR-0002", "后刹车片", "BP-R125", "125cc 半金属", "套", 22.00, 48.00, 250, "制动系统", "半金属配方后刹片"),
    ("P-BR-0003", "刹车盘", "BD-240", "240mm 打孔通风", "个", 118.00, 210.00, 80, "制动系统", "不锈钢打孔通风刹车盘"),
    ("P-BR-0004", "刹车油管", "BL-900", "900mm 编织钢喉", "根", 42.00, 78.00, 160, "制动系统", "钢丝编织刹车油管，耐压20MPa"),
    ("P-BR-0005", "刹车总泵", "BM-14", "14mm 活塞", "个", 96.00, 168.00, 60, "制动系统", "铝合金刹车总泵"),
    ("P-EL-0001", "蓄电池", "BT-12N7", "12V 7Ah 免维护", "个", 118.00, 198.00, 90, "电气系统", "免维护铅酸蓄电池"),
    ("P-EL-0002", "点火线圈", "IC-150", "150cc 高压", "个", 46.00, 88.00, 140, "电气系统", "双线高压点火线圈"),
    ("P-EL-0003", "整流稳压器", "RR-12V", "12V 三相", "个", 58.00, 105.00, 110, "电气系统", "三相整流稳压器，带过热保护"),
    ("P-EL-0004", "前大灯总成", "HL-LED", "LED 6000K", "个", 135.00, 245.00, 70, "电气系统", "LED透镜前大灯总成"),
    ("P-EL-0005", "转向灯", "TL-12V", "12V 琥珀色", "个", 8.50, 18.00, 400, "电气系统", "LED转向指示灯"),
    ("P-EL-0006", "启动电机", "SM-150", "150cc 直流", "个", 168.00, 295.00, 45, "电气系统", "永磁直流启动电机"),
    ("P-DR-0001", "驱动链条", "DC-428H", "428H 120节", "条", 65.00, 118.00, 180, "传动系统", "高强度滚子驱动链"),
    ("P-DR-0002", "前后链轮套件", "SP-428", "14T/38T", "套", 88.00, 158.00, 100, "传动系统", "前后链轮套装，含紧固件"),
    ("P-DR-0003", "离合器片", "CP-125", "125cc 纸基", "套", 72.00, 132.00, 130, "传动系统", "纸基摩擦片离合器总成"),
    ("P-DR-0004", "变速器总成", "GB-150", "150cc 5档", "套", 520.00, 880.00, 25, "传动系统", "五档常啮合变速器总成"),
    ("P-DR-0005", "传动皮带", "CB-669", "669-18-30", "条", 34.00, 65.00, 200, "传动系统", "CVT无级变速传动皮带"),
    ("P-FR-0001", "前减震器", "FS-320", "320mm 液压", "对", 210.00, 368.00, 55, "车架系统", "液压阻尼前减震器总成"),
    ("P-FR-0002", "后减震器", "RS-280", "280mm 弹簧", "对", 165.00, 298.00, 60, "车架系统", "可调弹簧后减震器"),
    ("P-FR-0003", "方向柱轴承", "SB-25", "25x47x15", "套", 26.00, 52.00, 220, "车架系统", "锥形滚子方向柱轴承"),
    ("P-FR-0004", "后平叉衬套", "SB-32", "32mm 尼龙", "个", 9.80, 22.00, 350, "车架系统", "耐磨尼龙后平叉衬套"),
    ("P-FR-0005", "主支架", "CS-01", "加固型 钢制", "个", 48.00, 92.00, 140, "车架系统", "加厚钢管主支架"),
    ("P-FL-0001", "空气滤清器", "AF-125", "125cc 纸质", "个", 18.50, 38.00, 320, "滤清系统", "高流量纸质空气滤芯"),
    ("P-FL-0002", "机油滤清器", "OF-150", "150cc 旋装", "个", 15.00, 32.00, 380, "滤清系统", "旋装式机油滤清器"),
    ("P-FL-0003", "汽油滤清器", "FF-8", "8mm 透明", "个", 6.50, 15.00, 500, "滤清系统", "透明壳体汽油滤清器"),
    ("P-FL-0004", "滤清器总成套件", "FK-01", "三滤套装", "套", 36.00, 72.00, 160, "滤清系统", "空滤+机滤+汽滤三件套"),
]

_WAREHOUSES = ["A区-01-01", "A区-02-03", "B区-01-05", "B区-03-02", "C区-02-01", "C区-04-04"]


def seed() -> None:
    """构建固定种子数据。日期锚定启动当天，向前铺开 6 个月。"""
    rng = random.Random(42)

    for i, (name, person, phone, email, addr, rating, status) in enumerate(_SUPPLIER_SEED, 1):
        store.suppliers.append({
            "id": i,
            "supplierCode": f"SUP{i:04d}",
            "name": name,
            "contactPerson": person,
            "phone": phone,
            "email": email,
            "address": addr,
            "creditRating": rating,
            "status": status,
            "createTime": (NOW - timedelta(days=400 - i * 5)).strftime("%Y-%m-%d %H:%M:%S"),
        })
    store._seq["supplier"] = len(_SUPPLIER_SEED)

    # 零部件按供货能力分派给「合作中」的供应商
    active_suppliers = [s["id"] for s in store.suppliers if s["status"] == 1]
    for i, seed_row in enumerate(_PART_SEED, 1):
        (code, name, model, spec, unit, price, retail, warn, category, desc) = seed_row
        store.parts.append({
            "id": i,
            "partCode": code,
            "name": name,
            "model": model,
            "specification": spec,
            "unit": unit,
            "purchasePrice": price,
            "suggestedRetailPrice": retail,
            "stockWarningValue": warn,
            "supplierId": active_suppliers[(i - 1) % len(active_suppliers)],
            "category": category,
            "description": desc,
        })
    store._seq["part"] = len(_PART_SEED)

    # 每个零件一条库存记录；留出 8 条低于预警值的制造预警
    low_stock_idx = {3, 11, 20, 24, 7, 15, 27, 30}
    for i, part in enumerate(store.parts, 1):
        warn = part["stockWarningValue"]
        qty = rng.randint(int(warn * 0.35), int(warn * 0.85)) if i in low_stock_idx \
            else rng.randint(int(warn * 1.2), int(warn * 3.5))
        store.inventory.append({
            "id": i,
            "partId": part["id"],
            "currentQuantity": qty,
            "safetyStock": warn,
            "warehouseLocation": _WAREHOUSES[(i - 1) % len(_WAREHOUSES)],
            "lastUpdateTime": (NOW - timedelta(days=rng.randint(0, 30))).strftime("%Y-%m-%d %H:%M:%S"),
        })
    store._seq["inventory"] = len(store.parts)

    # 订单：过去 180 天，31 张单，状态覆盖 0-4
    for n in range(1, 32):
        days_ago = 180 - n * 5 + rng.randint(-2, 2)
        days_ago = max(0, days_ago)
        order_time = NOW - timedelta(days=days_ago, hours=rng.randint(0, 10))
        status = rng.choices([0, 1, 2, 3, 4], weights=[1, 2, 3, 3, 4])[0]
        order = {
            "id": n,
            "orderNumber": f"PO{order_time.strftime('%Y%m%d')}{n:03d}",
            "totalAmount": 0.0,
            "status": status,
            "orderTime": order_time.strftime("%Y-%m-%d %H:%M:%S"),
            "remark": rng.choice(["常规补货", "季度集采", "紧急采购", "促销备货", ""]),
        }
        detail_count = rng.randint(1, 4)
        picked = rng.sample(store.parts, detail_count)
        total = 0.0
        for part in picked:
            qty = rng.randint(10, 200)
            # 单价围绕采购价小幅浮动，制造比价空间
            unit_price = round(part["purchasePrice"] * rng.uniform(0.92, 1.08), 2)
            store._seq["detail"] += 1
            store.order_details.append({
                "id": store._seq["detail"],
                "orderId": n,
                "partId": part["id"],
                "quantity": qty,
                "unitPrice": unit_price,
                "remark": "",
            })
            total += qty * unit_price
        order["totalAmount"] = round(total, 2)
        store.orders.append(order)
    store._seq["order"] = 31


seed()


# ============================================================
# 查询辅助
# ============================================================

def paginate(rows: list[dict], current: int, size: int) -> dict:
    current = max(1, current)
    size = max(1, size)
    total = len(rows)
    start = (current - 1) * size
    return {
        "records": rows[start:start + size],
        "total": total,
        "current": current,
        "size": size,
        "pages": (total + size - 1) // size,
    }


def find_supplier(sid: int) -> Optional[dict]:
    return next((s for s in store.suppliers if s["id"] == sid), None)


def find_part(pid: int) -> Optional[dict]:
    return next((p for p in store.parts if p["id"] == pid), None)


def find_inventory_by_part(pid: int) -> Optional[dict]:
    return next((v for v in store.inventory if v["partId"] == pid), None)


def part_with_supplier(part: dict) -> dict:
    """零件详情附带供应商摘要，供订单明细/库存接口使用。"""
    supplier = find_supplier(part["supplierId"])
    return {
        **part,
        "supplierName": supplier["name"] if supplier else None,
        "supplierCode": supplier["supplierCode"] if supplier else None,
        "creditRating": supplier["creditRating"] if supplier else None,
    }


def parse_date_bound(value: Optional[str], *, end: bool = False) -> Optional[datetime]:
    """接受 yyyy-MM-dd 或 yyyy-MM-dd HH:mm:ss。"""
    if not value:
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(value, fmt)
        except ValueError:
            continue
        if end and fmt == "%Y-%m-%d":
            dt = dt.replace(hour=23, minute=59, second=59)
        return dt
    return None


def in_range(ts: str, start: Optional[str], end: Optional[str]) -> bool:
    try:
        dt = datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")
    except (ValueError, TypeError):
        return False
    lo, hi = parse_date_bound(start), parse_date_bound(end, end=True)
    if lo and dt < lo:
        return False
    if hi and dt > hi:
        return False
    return True


app = FastAPI(title="Mock ERP Backend", version="1.0.0")


@app.get("/")
async def root():
    return ok({"service": "mock-erp", "suppliers": len(store.suppliers),
               "parts": len(store.parts), "orders": len(store.orders)})


@app.get("/health")
async def health():
    """容器 healthcheck 用，不依赖种子数据是否已加载。"""
    return {"status": "ok"}


# ============================================================
# 供应商 /api/suppliers/*
# ============================================================

@app.get("/api/suppliers/search")
async def suppliers_search(name: str = Query("")):
    kw = (name or "").strip()
    rows = [s for s in store.suppliers if kw in s["name"]] if kw else list(store.suppliers)
    return ok(rows)


@app.get("/api/suppliers/page")
async def suppliers_page(
    current: int = 1,
    size: int = 10,
    name: Optional[str] = None,
    status: Optional[int] = None,
    creditRating: Optional[str] = None,
):
    rows = list(store.suppliers)
    if name:
        rows = [s for s in rows if name in s["name"]]
    if status is not None:
        rows = [s for s in rows if s["status"] == status]
    if creditRating:
        rows = [s for s in rows if s["creditRating"] == creditRating]
    return ok(paginate(rows, current, size))


@app.get("/api/suppliers/get/{sid}")
async def suppliers_get(sid: int):
    supplier = find_supplier(sid)
    if not supplier:
        return fail(f"供应商不存在: {sid}", 404)
    return ok(supplier)


@app.post("/api/suppliers/create")
async def suppliers_create(payload: dict = Body(...)):
    code = payload.get("supplierCode")
    if not code:
        return fail("supplierCode 为必填")
    if any(s["supplierCode"] == code for s in store.suppliers):
        return fail(f"供应商编码已存在: {code}")
    supplier = {
        "id": store.next_id("supplier"),
        "supplierCode": code,
        "name": payload.get("name"),
        "contactPerson": payload.get("contactPerson"),
        "phone": payload.get("phone"),
        "email": payload.get("email"),
        "address": payload.get("address"),
        "creditRating": payload.get("creditRating"),
        "status": payload.get("status", 1),
        "createTime": NOW.strftime("%Y-%m-%d %H:%M:%S"),
    }
    store.suppliers.append(supplier)
    return ok(supplier, "创建成功")


@app.patch("/api/suppliers/update-status/{sid}")
async def suppliers_update_status(sid: int, status: int = Query(...)):
    supplier = find_supplier(sid)
    if not supplier:
        return fail(f"供应商不存在: {sid}", 404)
    supplier["status"] = status
    return ok(supplier, "状态更新成功")


# ============================================================
# 零部件 /api/parts/*
# ============================================================

@app.get("/api/parts/get/{pid}")
async def parts_get(pid: int):
    part = find_part(pid)
    if not part:
        return fail(f"零部件不存在: {pid}", 404)
    return ok(part_with_supplier(part))


@app.get("/api/parts/search")
async def parts_search(name: str = Query("")):
    kw = (name or "").strip()
    rows = [p for p in store.parts if kw in p["name"]] if kw else list(store.parts)
    return ok([part_with_supplier(p) for p in rows])


@app.get("/api/parts/supplier/{supplier_id}")
async def parts_by_supplier(supplier_id: int):
    if not find_supplier(supplier_id):
        return fail(f"供应商不存在: {supplier_id}", 404)
    rows = [p for p in store.parts if p["supplierId"] == supplier_id]
    return ok([part_with_supplier(p) for p in rows])


@app.get("/api/parts/page")
async def parts_page(
    current: int = 1,
    size: int = 10,
    name: Optional[str] = None,
    category: Optional[str] = None,
    supplierId: Optional[int] = None,
):
    rows = list(store.parts)
    if name:
        rows = [p for p in rows if name in p["name"]]
    if category:
        rows = [p for p in rows if p["category"] == category]
    if supplierId is not None:
        rows = [p for p in rows if p["supplierId"] == supplierId]
    page = paginate(rows, current, size)
    page["records"] = [part_with_supplier(p) for p in page["records"]]
    return ok(page)


@app.post("/api/parts/create")
async def parts_create(payload: dict = Body(...)):
    code = payload.get("partCode")
    if not code:
        return fail("partCode 为必填")
    if any(p["partCode"] == code for p in store.parts):
        return fail(f"零件编码已存在: {code}")
    price = payload.get("purchasePrice")
    if price is None:
        return fail("purchasePrice 为必填")
    if float(price) < 0:
        return fail("purchasePrice 必须 >= 0")
    supplier_id = payload.get("supplierId")
    if supplier_id is not None and not find_supplier(supplier_id):
        return fail(f"供应商不存在: {supplier_id}", 404)

    part = {
        "id": store.next_id("part"),
        "partCode": code,
        "name": payload.get("name"),
        "model": payload.get("model"),
        "specification": payload.get("specification"),
        "unit": payload.get("unit"),
        "purchasePrice": float(price),
        "suggestedRetailPrice": payload.get("suggestedRetailPrice"),
        "stockWarningValue": payload.get("stockWarningValue"),
        "supplierId": supplier_id,
        "category": payload.get("category"),
        "description": payload.get("description"),
    }
    store.parts.append(part)

    # 新零件同步建立库存记录，库存为 0 直接进入预警
    store.inventory.append({
        "id": store.next_id("inventory"),
        "partId": part["id"],
        "currentQuantity": 0,
        "safetyStock": payload.get("stockWarningValue") or 0,
        "warehouseLocation": "待分配",
        "lastUpdateTime": NOW.strftime("%Y-%m-%d %H:%M:%S"),
    })
    return ok(part, "创建成功")


# ============================================================
# 采购订单 /api/orders/*
# ============================================================

def _build_detail(order_id: int, item: dict) -> dict:
    store._seq["detail"] += 1
    return {
        "id": store._seq["detail"],
        "orderId": order_id,
        "partId": item.get("partId"),
        "quantity": item.get("quantity"),
        "unitPrice": item.get("unitPrice"),
        "remark": item.get("remark", ""),
    }


@app.post("/api/orders/create")
async def orders_create(payload: dict = Body(...)):
    details = payload.get("orderDetail") or []
    if not details:
        return fail("orderDetail 不能为空")
    for idx, item in enumerate(details):
        if not find_part(item.get("partId")):
            return fail(f"orderDetail[{idx}].partId 对应的零部件不存在: {item.get('partId')}", 404)
        if not item.get("quantity") or int(item["quantity"]) < 1:
            return fail(f"orderDetail[{idx}].quantity 必须 >= 1")
        if item.get("unitPrice") is None:
            return fail(f"orderDetail[{idx}].unitPrice 为必填")

    order_id = store.next_id("order")
    computed = round(sum(int(d["quantity"]) * float(d["unitPrice"]) for d in details), 2)
    order_time = NOW.strftime("%Y-%m-%d %H:%M:%S")
    order = {
        "id": order_id,
        "orderNumber": payload.get("orderNumber") or f"PO{NOW.strftime('%Y%m%d')}{order_id:03d}",
        "totalAmount": float(payload.get("totalAmount") or computed),
        "status": int(payload.get("status", 0)),
        "orderTime": order_time,
        "remark": payload.get("remark", ""),
    }
    store.orders.append(order)
    for item in details:
        store.order_details.append(_build_detail(order_id, item))

    order["orderDetail"] = _details_of(order_id)
    return ok(order, "创建成功")


def _details_of(order_id: int) -> list[dict]:
    out = []
    for d in store.order_details:
        if d["orderId"] != order_id:
            continue
        part = find_part(d["partId"])
        out.append({
            **d,
            "partName": part["name"] if part else None,
            "partCode": part["partCode"] if part else None,
            "model": part["model"] if part else None,
            "unit": part["unit"] if part else None,
            "subtotal": round(float(d["quantity"]) * float(d["unitPrice"]), 2),
            "supplierName": (find_supplier(part["supplierId"])["name"]
                             if part and find_supplier(part["supplierId"]) else None),
        })
    return out


@app.put("/api/orders/update/{oid}")
async def orders_update(oid: int, payload: dict = Body(...)):
    order = next((o for o in store.orders if o["id"] == oid), None)
    if not order:
        return fail(f"订单不存在: {oid}", 404)

    details = payload.get("orderDetail")
    if details:
        for idx, item in enumerate(details):
            if not find_part(item.get("partId")):
                return fail(f"orderDetail[{idx}].partId 对应的零部件不存在: {item.get('partId')}", 404)
        store.order_details = [d for d in store.order_details if d["orderId"] != oid]
        for item in details:
            store.order_details.append(_build_detail(oid, item))
        computed = round(sum(int(d["quantity"]) * float(d["unitPrice"]) for d in details), 2)
        order["totalAmount"] = float(payload.get("totalAmount") or computed)

    for field in ("orderNumber", "status", "remark"):
        if payload.get(field) is not None:
            order[field] = int(payload[field]) if field == "status" else payload[field]
    if payload.get("totalAmount") is not None and not details:
        order["totalAmount"] = float(payload["totalAmount"])

    order["orderDetail"] = _details_of(oid)
    return ok(order, "更新成功")


@app.get("/api/orders/page")
async def orders_page(
    current: int = 1,
    size: int = 10,
    orderNumber: Optional[str] = None,
    status: Optional[int] = None,
    startDate: Optional[str] = None,
    endDate: Optional[str] = None,
):
    rows = list(store.orders)
    if orderNumber:
        rows = [o for o in rows if orderNumber in o["orderNumber"]]
    if status is not None:
        rows = [o for o in rows if o["status"] == status]
    if startDate or endDate:
        rows = [o for o in rows if in_range(o["orderTime"], startDate, endDate)]
    rows.sort(key=lambda o: o["orderTime"], reverse=True)
    return ok(paginate(rows, current, size))


@app.get("/api/orders/get/{oid}")
async def orders_get(oid: int):
    order = next((o for o in store.orders if o["id"] == oid), None)
    if not order:
        return fail(f"订单不存在: {oid}", 404)
    return ok({**order, "orderDetail": _details_of(oid)})


@app.get("/api/orders/search-details")
async def orders_search_details(
    partName: Optional[str] = None,
    startDate: Optional[str] = None,
    endDate: Optional[str] = None,
):
    order_by_id = {o["id"]: o for o in store.orders}
    rows = []
    for d in store.order_details:
        order = order_by_id.get(d["orderId"])
        if not order:
            continue
        part = find_part(d["partId"])
        if not part:
            continue
        if partName and partName not in part["name"]:
            continue
        if (startDate or endDate) and not in_range(order["orderTime"], startDate, endDate):
            continue
        supplier = find_supplier(part["supplierId"])
        rows.append({
            **d,
            "orderNumber": order["orderNumber"],
            "orderTime": order["orderTime"],
            "orderStatus": order["status"],
            "partName": part["name"],
            "partCode": part["partCode"],
            "model": part["model"],
            "category": part["category"],
            "unit": part["unit"],
            "purchasePrice": part["purchasePrice"],
            "subtotal": round(float(d["quantity"]) * float(d["unitPrice"]), 2),
            "supplierId": part["supplierId"],
            "supplierName": supplier["name"] if supplier else None,
            "creditRating": supplier["creditRating"] if supplier else None,
        })
    rows.sort(key=lambda r: r["orderTime"], reverse=True)
    return ok(rows)


@app.get("/api/orders/statistics")
async def orders_statistics(startDate: Optional[str] = None, endDate: Optional[str] = None):
    rows = list(store.orders)
    if startDate or endDate:
        rows = [o for o in rows if in_range(o["orderTime"], startDate, endDate)]

    status_names = {0: "待审核", 1: "已审核", 2: "已发货", 3: "已收货", 4: "已完成"}
    by_status = [
        {
            "status": st,
            "statusName": status_names[st],
            "count": sum(1 for o in rows if o["status"] == st),
            "amount": round(sum(o["totalAmount"] for o in rows if o["status"] == st), 2),
        }
        for st in sorted(status_names)
    ]

    order_ids = {o["id"] for o in rows}
    items = [d for d in store.order_details if d["orderId"] in order_ids]
    part_ids = {d["partId"] for d in items}
    supplier_ids = {p["supplierId"] for p in store.parts if p["id"] in part_ids}

    return ok({
        "totalOrders": len(rows),
        "totalAmount": round(sum(o["totalAmount"] for o in rows), 2),
        "totalQuantity": sum(int(d["quantity"]) for d in items),
        "totalItems": len(items),
        "distinctParts": len(part_ids),
        "distinctSuppliers": len(supplier_ids),
        "byStatus": by_status,
        "startDate": startDate,
        "endDate": endDate,
    })


@app.patch("/api/orders/update-status/{oid}")
async def orders_update_status(oid: int, status: int = Query(...)):
    order = next((o for o in store.orders if o["id"] == oid), None)
    if not order:
        return fail(f"订单不存在: {oid}", 404)
    if status not in (0, 1, 2, 3, 4):
        return fail("status 取值必须为 0-4")
    order["status"] = status
    return ok(order, "状态更新成功")


# ============================================================
# 库存 /api/inventory/*
# ============================================================

def inventory_view(inv: dict) -> dict:
    part = find_part(inv["partId"])
    return {
        **inv,
        "partDetail": part_with_supplier(part) if part else None,
        "isWarning": inv["currentQuantity"] < inv["safetyStock"],
    }


@app.get("/api/inventory/warning")
async def inventory_warning():
    rows = [inventory_view(v) for v in store.inventory
            if v["currentQuantity"] < v["safetyStock"]]
    rows.sort(key=lambda r: r["currentQuantity"] - r["safetyStock"])
    return ok(rows)


@app.get("/api/inventory/page")
async def inventory_page(
    current: int = 1,
    size: int = 10,
    partName: Optional[str] = None,
    warehouseLocation: Optional[str] = None,
):
    rows = list(store.inventory)
    if partName:
        rows = [v for v in rows
                if (p := find_part(v["partId"])) and partName in p["name"]]
    if warehouseLocation:
        rows = [v for v in rows if warehouseLocation in v["warehouseLocation"]]
    page = paginate(rows, current, size)
    page["records"] = [inventory_view(v) for v in page["records"]]
    return ok(page)


@app.get("/api/inventory/check")
async def inventory_check():
    total_value = 0.0
    warning = 0
    by_category: dict[str, int] = {}
    by_warehouse: dict[str, int] = {}
    for inv in store.inventory:
        part = find_part(inv["partId"])
        if not part:
            continue
        total_value += inv["currentQuantity"] * part["purchasePrice"]
        if inv["currentQuantity"] < inv["safetyStock"]:
            warning += 1
        by_category[part["category"]] = by_category.get(part["category"], 0) + inv["currentQuantity"]
        by_warehouse[inv["warehouseLocation"]] = \
            by_warehouse.get(inv["warehouseLocation"], 0) + inv["currentQuantity"]

    return ok({
        "totalSku": len(store.inventory),
        "warningCount": warning,
        "normalCount": len(store.inventory) - warning,
        "totalQuantity": sum(v["currentQuantity"] for v in store.inventory),
        "totalValue": round(total_value, 2),
        "byCategory": [{"category": k, "quantity": v} for k, v in sorted(by_category.items())],
        "byWarehouse": [{"warehouseLocation": k, "quantity": v}
                        for k, v in sorted(by_warehouse.items())],
        "checkTime": NOW.strftime("%Y-%m-%d %H:%M:%S"),
    })


@app.post("/api/inventory/inbound")
async def inventory_inbound(
    partId: int = Query(...),
    quantity: int = Query(...),
    warehouseLocation: Optional[str] = None,
):
    if quantity <= 0:
        return fail("quantity 必须 > 0")
    if not find_part(partId):
        return fail(f"零部件不存在: {partId}", 404)
    inv = find_inventory_by_part(partId)
    if not inv:
        inv = {
            "id": store.next_id("inventory"),
            "partId": partId,
            "currentQuantity": 0,
            "safetyStock": find_part(partId).get("stockWarningValue") or 0,
            "warehouseLocation": warehouseLocation or "待分配",
        }
        store.inventory.append(inv)
    inv["currentQuantity"] += quantity
    if warehouseLocation:
        inv["warehouseLocation"] = warehouseLocation
    inv["lastUpdateTime"] = NOW.strftime("%Y-%m-%d %H:%M:%S")
    return ok(inventory_view(inv), "入库成功")


@app.post("/api/inventory/outbound")
async def inventory_outbound(partId: int = Query(...), quantity: int = Query(...)):
    if quantity <= 0:
        return fail("quantity 必须 > 0")
    if not find_part(partId):
        return fail(f"零部件不存在: {partId}", 404)
    inv = find_inventory_by_part(partId)
    if not inv:
        return fail(f"该零部件无库存记录: {partId}", 404)
    if inv["currentQuantity"] < quantity:
        return fail(f"库存不足：当前 {inv['currentQuantity']}，需出库 {quantity}")
    inv["currentQuantity"] -= quantity
    inv["lastUpdateTime"] = NOW.strftime("%Y-%m-%d %H:%M:%S")
    return ok(inventory_view(inv), "出库成功")


@app.get("/api/inventory/get/{iid}")
async def inventory_get(iid: int):
    inv = next((v for v in store.inventory if v["id"] == iid), None)
    if not inv:
        return fail(f"库存记录不存在: {iid}", 404)
    return ok(inventory_view(inv))


if __name__ == "__main__":
    print(f"[mock-erp] 种子数据: {len(store.suppliers)} 供应商 / "
          f"{len(store.parts)} 零部件 / {len(store.orders)} 订单 / "
          f"{len(store.inventory)} 库存记录")
    print("[mock-erp] 监听 http://0.0.0.0:8081")
    uvicorn.run(app, host="0.0.0.0", port=8081)
