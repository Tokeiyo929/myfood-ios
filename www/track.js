/* 轨迹记录: 前台3秒 + Capacitor BackgroundGeolocation 原生后台 */
let trackTimer = null;
let bgTracking = false;
let mapPoints = [];
let lastSent = { lat: null, lng: null, t: 0 };

function shouldSend(lat, lng, now) {
  if (lastSent.lat == null) return true;
  const dLat = (lat - lastSent.lat) * 111320;
  const dLng = (lng - lastSent.lng) * 111320 * Math.cos(lastSent.lat * Math.PI / 180);
  const dist = Math.sqrt(dLat * dLat + dLng * dLng);
  const dt = (now - lastSent.t) / 1000;
  return dist > 2 || dt > 30; // 移动>2m 或 超30s 强制记一个点
}

async function startBackgroundTracking() {
  const BG = window.Capacitor?.Plugins?.BackgroundGeolocation;
  if (!BG) return false;
  try {
    await BG.watchPosition({
      packageName: "com.tokeiyo929.myfood",
      enableHighAccuracy: true,
      distanceInterval: 5,       // 移动5米触发
      heartbeatInterval: 15,     // 最长15秒必触发
    }, (loc) => {
      const lat = loc.latitude, lng = loc.longitude;
      const now = Date.now();
      if (!shouldSend(lat, lng, now)) return;
      lastSent = { lat, lng, t: now };
      mapPoints.push({ lat, lng });
      if (currentTab === "map" && !viewDay) drawMap();
      postPoints([{ lat, lng, ts: now, acc: loc.accuracy }]);
    });
    return true;
  } catch (e) { console.warn("bg geo fail", e); return false; }
}

async function stopBackgroundTracking() {
  const BG = window.Capacitor?.Plugins?.BackgroundGeolocation;
  if (BG) { try { await BG.removeWatcher({ id: undefined }); } catch (e) {} }
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
    if (viewDay) { viewDay = null; renderMapPage(); return; }
    btn.textContent = "停止记录";
    info.textContent = "记录中…(前台3秒/后台移动5米)";
    // 原生后台watcher(锁屏也活)
    bgTracking = await startBackgroundTracking();
    if (!bgTracking) info.textContent += " · 后台不可用,仅前台";
    // 前台加密定时器
    recordOnce();
    trackTimer = setInterval(recordOnce, 3000);
  } else {
    tracking = false;
    clearInterval(trackTimer);
    trackTimer = null;
    await stopBackgroundTracking();
    btn.textContent = "开始记录";
    info.textContent = "已停止";
    loadTodayTrack();
  }
}

async function recordOnce() {
  try {
    const pos = await window.Capacitor.Plugins.Geolocation.getCurrentPosition({ enableHighAccuracy: true, timeout: 5000 });
    const lat = pos.coords.latitude, lng = pos.coords.longitude;
    if (lat == null || lng == null) return;
    const now = Date.now();
    if (!shouldSend(lat, lng, now)) return;
    lastSent = { lat, lng, t: now };
    mapPoints.push({ lat, lng });
    mapState.centerX = lng; mapState.centerY = lat;
    drawMap();
    postPoints([{ lat, lng, ts: now, acc: pos.coords.accuracy }]);
  } catch (e) {
    // 静默: 后台watcher在跑时前台偶尔失败正常
  }
}
