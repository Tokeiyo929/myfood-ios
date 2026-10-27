/* MyFood iOS app - tab 架构 SPA (中心tab=地图, 默认打开) */
const app = document.getElementById("app");
let settings = null;
let todayRecords = [];
let currentTab = "map";

function el(html) { const d = document.createElement("div"); d.innerHTML = html; return d.firstElementChild; }
function toast(msg, ok) {
  const t = el(`<div style="position:fixed;left:50%;top:20%;transform:translateX(-50%);background:${ok ? "#66508f" : "#c0392b"};color:#fff;padding:10px 22px;border-radius:20px;font-size:14px;z-index:200">${msg}</div>`);
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 1800);
}
function fmtTime(v) { return (v || "").replace("T", " ").slice(0, 16); }
function priceText(p) {
  if (Array.isArray(p)) {
    const parts = [];
    if (p[0] != null) parts.push("原价 " + p[0]);
    if (p[1] != null) parts.push("折后 " + p[1]);
    return parts.join(" / ");
  }
  return p != null ? String(p) : "";
}

/* ---------- 底部 tab 栏 ---------- */
const TABS = [
  { id: "history", icon: "📋", label: "历史" },
  { id: "record", icon: "📸", label: "记录" },
  { id: "map", icon: "🗺", label: "地图", center: true },
  { id: "tracks", icon: "📅", label: "轨迹" },
  { id: "settings", icon: "⚙️", label: "设置" },
];

function renderTabBar() {
  const bar = el(`<div id="tabbar" style="position:fixed;left:0;right:0;bottom:0;background:#fff;border-top:1px solid #eee;display:flex;padding-bottom:env(safe-area-inset-bottom);z-index:50"></div>`);
  TABS.forEach((t) => {
    const active = currentTab === t.id;
    if (t.center) {
      const item = el(`<div style="flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;cursor:pointer;padding:4px 0">
        <div style="width:52px;height:52px;border-radius:50%;background:${active ? "#66508f" : "#8b74b3"};display:flex;align-items:center;justify-content:center;margin-top:-18px;box-shadow:0 2px 8px rgba(102,80,143,.4)"><span style="font-size:24px">🗺</span></div>
        <span style="font-size:11px;color:${active ? "#66508f" : "#999"};margin-top:2px">地图</span>
      </div>`);
      item.onclick = () => switchTab(t.id);
      bar.appendChild(item);
    } else {
      const item = el(`<div style="flex:1;display:flex;flex-direction:column;align-items:center;padding:8px 0;cursor:pointer">
        <span style="font-size:20px;filter:${active ? "none" : "grayscale(1)"};opacity:${active ? 1 : 0.5}">${t.icon}</span>
        <span style="font-size:11px;color:${active ? "#66508f" : "#999"};margin-top:2px">${t.label}</span>
      </div>`);
      item.onclick = () => switchTab(t.id);
      bar.appendChild(item);
    }
  });
  document.body.querySelectorAll("#tabbar").forEach((n) => n.remove());
  document.body.appendChild(bar);
}

function switchTab(id) {
  currentTab = id;
  renderTabBar();
  if (id === "map") renderMapPage();
  else if (id === "record") renderHome();
  else if (id === "history") renderHistory();
  else if (id === "tracks") renderTrackDays();
  else if (id === "settings") renderSettings();
}

/* ---------- 记录页 (原首页) ---------- */
async function renderHome() {
  app.innerHTML = `<div class="loading">加载中…</div>`;
  if (!settings) {
    try { settings = await api.getConfig(); } catch (e) { app.innerHTML = `<div class="empty">配置加载失败，点击重试</div>`; app.onclick = () => { app.onclick = null; renderHome(); }; return; }
  }
  await loadToday();
  drawHome();
}
async function loadToday() {
  try {
    const r = await api.getFoods(1, settings.pagination.max_page_size, "", true);
    todayRecords = r.items || [];
  } catch (e) { toast("今日记录加载失败"); }
}
function drawHome() {
  app.innerHTML = "";
  app.appendChild(el(`<div class="section-title">今日记录</div>`));
  if (!todayRecords.length) app.appendChild(el(`<div class="empty">今天还没有记录</div>`));
  todayRecords.forEach((rec) => {
    const card = el(`<div class="record-card">
      ${rec.image_path ? `<img src="${api.imageUrl(rec.image_path)}" />` : ""}
      <div class="record-body">
        <div class="record-name">${rec.name || "未命名"}</div>
        <div class="record-time">${fmtTime(rec.taken_at || rec.create_at)}</div>
      </div>
      <div class="record-comment-btn">💬</div>
    </div>`);
    card.onclick = () => renderDetail(rec.id);
    card.querySelector(".record-comment-btn").onclick = (e) => { e.stopPropagation(); openComment(rec); };
    app.appendChild(card);
  });
  const actions = el(`<div class="actions" style="margin-top:16px">
    <div class="action-btn" id="btnAlbum"><span class="ico">🖼</span><span class="txt">从相册选</span></div>
    <div class="action-btn" id="btnCamera"><span class="ico">📷</span><span class="txt">拍照</span></div>
  </div>`);
  app.appendChild(actions);
  document.getElementById("btnAlbum").onclick = () => saveQuick();
  document.getElementById("btnCamera").onclick = () => saveQuick();
}

async function saveQuick() {
  if (!settings) { toast("配置加载中"); return; }
  try {
    const upload = await api.pickAndUpload(settings.image);
    const record = {
      name: "", brand_name: "", price: null, categories: [], ingredients: [], flavors: [],
      preference: settings.preferences.good.value, comment: [],
      image_path: upload.path, image_metadata: upload.metadata || {},
      client_key: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10),
    };
    await api.submitFood(record);
    toast("已保存", true);
    await loadToday();
    drawHome();
  } catch (e) {
    if ((e.message || "").indexOf("未选择") === -1) toast(e.message || "保存失败");
  }
}

/* ---------- 历史列表 ---------- */
async function renderHistory() {
  app.innerHTML = `<div class="loading">加载中…</div>`;
  let items = [];
  try {
    let page = 1;
    while (true) {
      const r = await api.getFoods(page, 50, "", false);
      items = items.concat(r.items || []);
      if (!r.items || r.items.length < 50 || page >= 20) break;
      page++;
    }
  } catch (e) { app.innerHTML = `<div class="empty">加载失败</div>`; return; }
  app.innerHTML = "";
  app.appendChild(el(`<div class="section-title">全部记录 (${items.length})</div>`));
  if (!items.length) app.appendChild(el(`<div class="empty">还没有记录</div>`));
  items.forEach((rec) => {
    const card = el(`<div class="record-card">
      ${rec.image_path ? `<img src="${api.imageUrl(rec.image_path)}" />` : ""}
      <div class="record-body">
        <div class="record-name">${rec.name || "未命名"}</div>
        <div class="record-time">${fmtTime(rec.taken_at || rec.create_at)}</div>
      </div>
    </div>`);
    card.onclick = () => renderDetail(rec.id);
    app.appendChild(card);
  });
}

/* ---------- 评论 ---------- */
function openComment(rec) {
  const mask = el(`<div class="mask"><div class="panel">
    <h3>评论</h3>
    <div id="cpList"></div>
    <textarea id="cpInput" placeholder="写评论..."></textarea>
    <div class="actions-bar"><div class="btn plain" id="cpCancel">取消</div><div class="btn primary" id="cpSave">保存</div></div>
  </div></div>`);
  const list = mask.querySelector("#cpList");
  (rec.comment || []).forEach((c) => list.appendChild(el(`<div class="comment-item">${c}</div>`)));
  mask.onclick = (e) => { if (e.target === mask) mask.remove(); };
  mask.querySelector("#cpCancel").onclick = () => mask.remove();
  mask.querySelector("#cpSave").onclick = async () => {
    const text = mask.querySelector("#cpInput").value.trim();
    if (!text) { toast("请输入评论"); return; }
    try {
      await api.addComment(rec.id, (rec.comment || []).concat([text]));
      mask.remove(); toast("已评论", true); await loadToday(); drawHome();
    } catch (e) { toast(e.message || "保存失败"); }
  };
  document.body.appendChild(mask);
}

/* ---------- 详情页 ---------- */
async function renderDetail(id) {
  app.innerHTML = `<div class="loading">加载中…</div>`;
  let food;
  try { food = await api.getFoodById(id); } catch (e) { app.innerHTML = `<div class="empty">加载失败</div>`; return; }
  app.innerHTML = "";
  app.appendChild(el(`<span class="back" id="backBtn">‹</span>`));
  if (food.image_path) {
    const img = el(`<img class="hero" src="${api.imageUrl(food.image_path)}" />`);
    img.onclick = () => window.open(api.imageUrl(food.image_path));
    app.appendChild(img);
  }
  const body = el(`<div>
    <div class="name">${food.name || "未命名"}</div>
    <div class="meta">${fmtTime(food.taken_at || food.create_at)}</div>
    ${priceText(food.price) ? `<div class="row"><span class="label">价格</span><span class="value">${priceText(food.price)}</span></div>` : ""}
    ${food.brand_name ? `<div class="row"><span class="label">品牌</span><span class="value">${food.brand_name}</span></div>` : ""}
    ${(food.categories || []).length ? `<div class="row"><span class="label">类别</span><span class="value">${food.categories.join("、")}</span></div>` : ""}
    ${(food.ingredients || []).length ? `<div class="row"><span class="label">原料</span><span class="value">${food.ingredients.map((i) => i.name + (i.amount ? "(" + i.amount + "%)" : "")).join("、")}</span></div>` : ""}
    <div class="actions-bar"><div class="btn primary" id="editBtn">编辑</div><div class="btn plain danger" id="delBtn">删除</div></div>
  </div>`);
  app.appendChild(body);
  (food.comment || []).forEach((c) => body.appendChild(el(`<div class="comment-item" style="margin-top:8px">${c}</div>`)));
  document.getElementById("backBtn").onclick = () => switchTab(currentTab);
  document.getElementById("editBtn").onclick = () => renderEdit(food);
  document.getElementById("delBtn").onclick = () => {
    if (!confirm("确定删除这条记录吗？")) return;
    api.deleteFood(id).then(() => { toast("已删除", true); switchTab(currentTab); }).catch((e) => toast(e.message || "删除失败"));
  };
}

/* ---------- 编辑页 ---------- */
function renderEdit(food) {
  const p = Array.isArray(food.price) ? food.price : [food.price, null];
  app.innerHTML = `<span class="back" id="backBtn">‹</span>
    <div class="form-item"><span class="label">名称</span><input id="fName" value="${food.name || ""}" placeholder="食物名称" /></div>
    <div class="form-item"><span class="label">品牌</span><input id="fBrand" value="${food.brand_name || ""}" placeholder="可空" /></div>
    <div class="form-item"><span class="label">原价</span><input id="fOrig" type="number" inputmode="decimal" value="${p[0] != null ? p[0] : ""}" placeholder="可空" /></div>
    <div class="form-item"><span class="label">折扣价</span><input id="fDisc" type="number" inputmode="decimal" value="${p[1] != null ? p[1] : ""}" placeholder="可空" /></div>
    <div class="form-item"><span class="label">类别</span><input id="fCats" value="${(food.categories || []).join(",")}" placeholder="逗号分隔" /></div>
    <div class="actions-bar"><div class="btn primary" id="saveBtn">保存</div><div class="btn plain" id="cancelBtn">取消</div></div>`;
  document.getElementById("backBtn").onclick = () => renderDetail(food.id);
  document.getElementById("cancelBtn").onclick = () => renderDetail(food.id);
  document.getElementById("saveBtn").onclick = async () => {
    const split = (t) => t.split(/[,，、]/).map((s) => s.trim()).filter(Boolean);
    const orig = document.getElementById("fOrig").value.trim();
    const disc = document.getElementById("fDisc").value.trim();
    const price = [orig === "" ? null : Number(orig), disc === "" ? null : Number(disc)];
    try {
      await api.updateFoodDetails(food.id, {
        name: document.getElementById("fName").value.trim(),
        brand_name: document.getElementById("fBrand").value.trim(),
        price,
        categories: split(document.getElementById("fCats").value),
      });
      toast("已保存", true);
      renderDetail(food.id);
    } catch (e) { toast(e.message || "保存失败"); }
  };
}

/* ---------- 轨迹天列表 ---------- */
async function renderTrackDays() {
  app.innerHTML = `<div class="loading">加载中…</div>`;
  let days = [];
  try { days = (await api.request("/api/tracks/days")).days || []; } catch (e) {}
  app.innerHTML = "";
  app.appendChild(el(`<div class="section-title">轨迹</div>`));
  if (!days.length) app.appendChild(el(`<div class="empty">还没有轨迹记录<br><span style="font-size:12px">去地图页点「开始记录」</span></div>`));
  days.forEach((d) => {
    const card = el(`<div class="record-card"><div class="record-body"><div class="record-name">${d.day}</div><div class="record-time">${d.points} 个定位点</div></div><span style="color:#999">›</span></div>`);
    card.onclick = () => { viewDay = d.day; switchTab("map"); };
    app.appendChild(card);
  });
}
let viewDay = null;

/* ---------- 设置页 ---------- */
function renderSettings() {
  app.innerHTML = `<div class="section-title">设置</div>
    <div class="record-card"><div class="record-body">
      <div class="record-name">后端</div>
      <div class="record-time">${api.BASE_URL}</div>
    </div></div>
    <div class="record-card"><div class="record-body">
      <div class="record-name">连接说明</div>
      <div class="record-time">后端需通过代理访问，请保持 Clash 开启</div>
    </div></div>
    <div class="record-card" id="clearTrack"><div class="record-body">
      <div class="record-name" style="color:#c0392b">清除本地缓存</div>
      <div class="record-time">重新加载配置与今日记录</div>
    </div></div>`;
  document.getElementById("clearTrack").onclick = () => { settings = null; todayRecords = []; toast("已清除", true); switchTab("record"); };
}

/* ---------- 启动 ---------- */
document.addEventListener("DOMContentLoaded", () => {
  app.style.paddingBottom = "80px";
  renderTabBar();
  switchTab("map");
});
