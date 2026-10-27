/* MyFood iOS - 地图轨迹页 (原生JS, 无外部地图库: 自绘canvas瓦片) */
let trackTimer = null;
let tracking = false;
let todayPoints = [];

function latLngToPixel(lat, lng, zoom) {
  const scale = 256 * Math.pow(2, zoom);
  const x = (lng + 180) / 360 * scale;
  const sinLat = Math.sin(lat * Math.PI / 180);
  const y = (0.5 - Math.log((1 + sinLat) / (1 - sinLat)) / (4 * Math.PI)) * scale;
  return { x, y };
}
function pixelToLatLng(x, y, zoom) {
  const scale = 256 * Math.pow(2, zoom);
  const lng = x / scale * 360 - 180;
  const n = Math.PI - 2 * Math.PI * y / scale;
  const lat = 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
  return { lat, lng };
}

function renderMapPage() {
  app.innerHTML = `<span class="back" id="backBtn">‹</span>
    <div class="section-title">行动轨迹</div>
    <div id="mapWrap" style="position:relative;width:100%;height:60vh;background:#e8ecf1;border-radius:12px;overflow:hidden">
      <canvas id="mapCanvas" style="width:100%;height:100%;touch-action:none"></canvas>
      <div id="mapStatus" style="position:absolute;left:8px;bottom:8px;background:rgba(255,255,255,.85);border-radius:8px;padding:4px 10px;font-size:12px;color:#555">加载中…</div>
    </div>
    <div class="actions-bar" style="margin-top:14px">
      <div class="btn primary" id="trackToggle">开始记录</div>
      <div class="btn plain" id="trackToday">今日轨迹</div>
    </div>
    <div id="trackInfo" style="margin-top:10px;font-size:13px;color:#666"></div>`;
  document.getElementById("backBtn").onclick = renderHome;
  document.getElementById("trackToggle").onclick = toggleTracking;
  document.getElementById("trackToday").onclick = loadTodayTrack;
  initMapCanvas();
  loadTodayTrack();
}

/* ---- 简易瓦片地图 (OSM) ---- */
const mapState = { zoom: 14, centerX: 119.2965, centerY: 26.0745, drag: null };
function initMapCanvas() {
  const canvas = document.getElementById("mapCanvas");
  canvas.addEventListener("touchstart", (e) => {
    const t = e.touches[0];
    mapState.drag = { x: t.clientX, y: t.clientY };
  });
  canvas.addEventListener("touchmove", (e) => {
    if (!mapState.drag) return;
    const t = e.touches[0];
    const dx = t.clientX - mapState.drag.x, dy = t.clientY - mapState.drag.y;
    mapState.drag = { x: t.clientX, y: t.clientY };
    const c = latLngToPixel(mapState.centerY, mapState.centerX, mapState.zoom);
    mapState.centerX = pixelToLatLng(c.x - dx, c.y - dy, mapState.zoom).lng;
    mapState.centerY = pixelToLatLng(c.x - dx, c.y - dy, mapState.zoom).lat;
    drawMap();
    e.preventDefault();
  }, { passive: false });
  canvas.addEventListener("touchend", () => { mapState.drag = null; });
  drawMap();
}

function drawMap() {
  const canvas = document.getElementById("mapCanvas");
  const wrap = document.getElementById("mapWrap");
  if (!canvas) return;
  const dpr = window.devicePixelRatio || 1;
  const W = wrap.clientWidth, H = wrap.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  ctx.fillStyle = "#dde3ea"; ctx.fillRect(0, 0, W, H);

  const zoom = mapState.zoom;
  const center = latLngToPixel(mapState.centerY, mapState.centerX, zoom);
  const tileSize = 256;
  const tiles = [];
  const x0 = Math.floor((center.x - W / 2) / tileSize), x1 = Math.floor((center.x + W / 2) / tileSize);
  const y0 = Math.floor((center.y - H / 2) / tileSize), y1 = Math.floor((center.y + H / 2) / tileSize);
  const maxTile = Math.pow(2, zoom) - 1;
  let pending = 0;
  for (let tx = x0; tx <= x1; tx++) for (let ty = y0; ty <= y1; ty++) {
    if (ty < 0 || ty > maxTile) continue;
    const wx = ((tx % Math.pow(2, zoom)) + Math.pow(2, zoom)) % Math.pow(2, zoom);
    tiles.push({ tx: wx, ty, px: tx * tileSize - center.x + W / 2, py: ty * tileSize - center.y + H / 2 });
  }
  const status = document.getElementById("mapStatus");
  tiles.forEach((t) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => { ctx.drawImage(img, t.px, t.py, tileSize, tileSize); drawTrack(ctx, W, H); };
    img.onerror = () => { pending++; if (pending === tiles.length && status) status.textContent = "地图瓦片加载失败(需代理)"; };
    img.src = "https://tile.openstreetmap.org/" + zoom + "/" + t.tx + "/" + t.ty + ".png";
  });

  drawTrack(ctx, W, H);
  function drawTrack(ctx, W, H) {
    if (!todayPoints.length) return;
    ctx.strokeStyle = "#66508f"; ctx.lineWidth = 3; ctx.lineJoin = "round";
    ctx.beginPath();
    todayPoints.forEach((p, i) => {
      const pt = latLngToPixel(p.lat, p.lng, zoom);
      const sx = pt.x - center.x + W / 2, sy = pt.y - center.y + H / 2;
      if (i === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy);
    });
    ctx.stroke();
    // 起终点
    const first = latLngToPixel(todayPoints[0].lat, todayPoints[0].lng, zoom);
    const last = latLngToPixel(todayPoints[todayPoints.length - 1].lat, todayPoints[todayPoints.length - 1].lng, zoom);
    ctx.fillStyle = "#2e7d32";
    ctx.beginPath(); ctx.arc(first.x - center.x + W / 2, first.y - center.y + H / 2, 5, 0, 7); ctx.fill();
    ctx.fillStyle = "#c0392b";
    ctx.beginPath(); ctx.arc(last.x - center.x + W / 2, last.y - center.y + H / 2, 5, 0, 7); ctx.fill();
  }
  if (status) status.textContent = "缩放" + zoom + " · " + todayPoints.length + "点";
}

async function loadTodayTrack() {
  const day = new Date().toISOString().slice(0, 10);
  try {
    const r = await api.request("/api/tracks?day=" + day);
    todayPoints = (r.points || []).map((p) => ({ lat: Number(p.lat), lng: Number(p.lng) }));
    if (todayPoints.length) {
      const last = todayPoints[todayPoints.length - 1];
      mapState.centerX = last.lng; mapState.centerY = last.lat;
    }
    drawMap();
  } catch (e) {
    const st = document.getElementById("mapStatus");
    if (st) st.textContent = "轨迹加载失败";
  }
}

async function postPoints(points) {
  try { await api.request("/api/tracks", "POST", { points }); } catch (e) { console.warn("track post fail", e); }
}

async function toggleTracking() {
  const btn = document.getElementById("trackToggle");
  const info = document.getElementById("trackInfo");
  if (!tracking) {
    try {
      const perm = await window.Capacitor.Plugins.Geolocation.checkPermissions();
      if (perm.location !== "granted" && perm.coarseLocation !== "granted") {
        await window.Capacitor.Plugins.Geolocation.requestPermissions();
      }
    } catch (e) {}
    tracking = true;
    btn.textContent = "停止记录";
    info.textContent = "记录中…(每10秒上报一次)";
    // 立即记一次
    recordOnce();
    trackTimer = setInterval(recordOnce, 10000);
  } else {
    tracking = false;
    clearInterval(trackTimer);
    trackTimer = null;
    btn.textContent = "开始记录";
    info.textContent = "已停止";
    loadTodayTrack();
  }
}

async function recordOnce() {
  try {
    const pos = await window.Capacitor.Plugins.Geolocation.getCurrentPosition({ enableHighAccuracy: true, timeout: 8000 });
    const lat = pos.coords.latitude, lng = pos.coords.longitude;
    if (lat == null || lng == null) return;
    // 本地也画上
    todayPoints.push({ lat, lng });
    drawMap();
    postPoints([{ lat, lng, ts: Date.now(), acc: pos.coords.accuracy }]);
  } catch (e) {
    const info = document.getElementById("trackInfo");
    if (info) info.textContent = "定位失败: " + (e.message || e);
  }
}
