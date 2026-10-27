/* MyFood iOS app - vanilla JS SPA */
const app = document.getElementById("app");
let settings = null;
let todayRecords = [];

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

/* ---------- 记录页 ---------- */
async function renderHome() {
  app.innerHTML = `<div class="loading">加载中…</div>`;
  if (!settings) {
    try { settings = await api.getConfig(); } catch (e) { app.innerHTML = `<div class="empty">配置加载失败，点击重试</div>`; app.onclick = renderHome; return; }
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
  const actions = el(`<div class="actions">
    <div class="action-btn" id="btnAlbum"><span class="ico">🖼</span><span class="txt">从相册选</span></div>
    <div class="action-btn" id="btnCamera"><span class="ico">📷</span><span class="txt">拍照</span></div>
  </div>`);
  app.appendChild(actions);
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
}

async function saveQuick(sourceType) {
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
  document.getElementById("backBtn").onclick = renderHome;
  document.getElementById("editBtn").onclick = () => renderEdit(food);
  document.getElementById("delBtn").onclick = () => {
    if (!confirm("确定删除这条记录吗？")) return;
    api.deleteFood(id).then(() => { toast("已删除", true); renderHome(); }).catch((e) => toast(e.message || "删除失败"));
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

/* ---------- 启动 ---------- */
document.addEventListener("DOMContentLoaded", renderHome);
