/* MyFood iOS - 地图 tab (中心tab, 默认打开) */
let trackTimer = null;
let tracking = false;
let mapPoints = [];

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
  app.innerHTML = `
    <div class="section-title">${viewDay ? "轨迹 · " + viewDay : "地图"}</div>
    <div id="mapWrap" style="position:relative;width:100%;height:calc(100vh - 190px);min-height:340px;background:#e8ecf1;border-radius:12px;overflow:hidden">
      <canvas id="mapCanvas" style="width:100%;height:100%;touch-action:none"></canvas>
      <div id="mapStatus" style="position:absolute;left:8px;bottom:8px;background:rgba(255,255,255,.85);border-radius:8px;padding:4px 10px;font-size:12px;color:#555">加载中…</div>
      <div style="position:absolute;right:8px;top:8px;display:flex;flex-direction:column;gap:6px">
        <div id="zoomIn" style="width:34px;height:34px;background:#fff;border-radius:8px;text-align:center;line-height:34px;font-size:18px;cursor:pointer;box-shadow:0 1px 4px rgba(0,0,0,.15)">＋</div>
        <div id="zoomOut" style="width:34px;height:34px;background:#fff;border-radius:8px;text-align:center;line-height:34px;font-size:18px;cursor:pointer;box-shadow:0 1px 4px rgba(0,0,0,.15)">－</div>
      </div>
    </div>
    <div class="actions-bar" style="margin-top:12px">
      <div class="btn primary" id="trackToggle">${tracking ? "停止记录" : "开始记录"}</div>
      <div class="btn plain" id="trackToday">${viewDay ? "回到今日" : "今日轨迹"}</div>
    </div>
    <div id="trackInfo" style="margin-top:8px;font-size:13px;color:#666"></div>`;
  document.getElementById("trackToggle").onclick = toggleTracking;
  document.getElementById("trackToday").onclick = () => { viewDay = null; loadTodayTrack(); renderMapPage(); };
  document.getElementById("zoomIn").onclick = () => { mapState.zoom = Math.min(18, mapState.zoom + 1); drawMap(); };
  document.getElementById("zoomOut").onclick = () => { mapState.zoom = Math.max(3, mapState.zoom - 1); drawMap(); };
  initMapCanvas();
  if (viewDay) loadDayTrack(viewDay); else loadTodayTrack();
}

/* ---- 瓦片地图 (OSM) ---- */
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
    const ll = pixelToLatLng(c.x - dx, c.y - dy, mapState.zoom);
    mapState.centerX = ll.lng; mapState.centerY = ll.lat;
    drawMap();
    e.preventDefault();
  }, { passive: false });
  canvas.addEventListener("touchend", () => { mapState.drag = null; });
  drawMap();
}

function drawMap() {
  const canvas = document.getElementById("mapCanvas");
  const wrap = document.getElementById("mapWrap");
  if (!canvas || !wrap) return;
  const dpr = window.devicePixelRatio || 1;
  const W = wrap.clientWidth, H = wrap.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = "#dde3ea"; ctx.fillRect(0, 0, W, H);

  const zoom = mapState.zoom;
  const center = latLngToPixel(mapState.centerY, mapState.centerX, zoom);
  const tileSize = 256;
  const x0 = Math.floor((center.x - W / 2) / tileSize), x1 = Math.floor((center.x + W / 2) / tileSize);
  const y0 = Math.floor((center.y - H / 2) / tileSize), y1 = Math.floor((center.y + H / 2) / tileSize);
  const maxTile = Math.pow(2, zoom) - 1;
  const N = Math.pow(2, zoom);
  for (let tx = x0; tx <= x1; tx++) for (let ty = y0; ty <= y1; ty++) {
    if (ty < 0 || ty > maxTile) continue;
    const wx = ((tx % N) + N) % N;
    const px = tx * tileSize - center.x + W / 2, py = ty * tileSize - center.y + H / 2;
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => { if (document.getElementById("mapCanvas") === canvas) { ctx.drawImage(img, px, py, tileSize, tileSize); drawTrack(); } };
    img.src = "https://tile.openstreetmap.org/" + zoom + "/" + wx + "/" + ty + ".png";
  }
  drawTrack();

  function drawTrack() {
    if (!mapPoints.length) return;
    ctx.strokeStyle = "#66508f"; ctx.lineWidth = 3; ctx.lineJoin = "round"; ctx.lineCap = "round";
    ctx.beginPath();
    mapPoints.forEach((p, i) => {
      const pt = latLngToPixel(p.lat, p.lng, zoom);
      const sx = pt.x - center.x + W / 2, sy = pt.y - center.y + H / 2;
      if (i === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy);
    });
    ctx.stroke();
    const first = latLngToPixel(mapPoints[0].lat, mapPoints[0].lng, zoom);
    const last = latLngToPixel(mapPoints[mapPoints.length - 1].lat, mapPoints[mapPoints.length - 1].lng, zoom);
    ctx.fillStyle = "#2e7d32";
    ctx.beginPath(); ctx.arc(first.x - center.x + W / 2, first.y - center.y + H / 2, 5, 0, 7); ctx.fill();
    ctx.fillStyle = "#c0392b";
    ctx.beginPath(); ctx.arc(last.x - center.x + W / 2, last.y - center.y + H / 2, 5, 0, 7); ctx.fill();
  }
  const status = document.getElementById("mapStatus");
  if (status) status.textContent = "缩放" + zoom + " · " + mapPoints.length + "点";
}

async function loadTodayTrack() {
  const day = new Date().toISOString().slice(0, 10);
  await loadDayTrack(day);
}
async function loadDayTrack(day) {
  try {
    const r = await api.request("/api/tracks?day=" + day);
    mapPoints = (r.points || []).map((p) => ({ lat: Number(p.lat), lng: Number(p.lng) }));
    if (mapPoints.length) {
      const last = mapPoints[mapPoints.length - 1];
      mapState.centerX = last.lng; mapState.centerY = last.lat;
    }
    drawMap();
  } catch (e) {
    const st = document.getElementById("mapStatus");
    if (st) st.textContent = "轨迹加载失败";
  }
}
