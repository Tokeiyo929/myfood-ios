const BASE_URL = "https://myfood-worker.keiyokaze.workers.dev";
const UPLOAD_TIMEOUT = 90000;

function request(path, method = "GET", data = null) {
  return new Promise((resolve, reject) => {
    fetch(BASE_URL + path, {
      method,
      headers: { "Content-Type": "application/json" },
      body: data ? JSON.stringify(data) : undefined,
    }).then(async (res) => {
      if (res.ok) resolve(await res.json());
      else {
        let msg = "HTTP " + res.statusCode;
        try { msg = (await res.json()).error || msg; } catch (e) {}
        reject(new Error(msg));
      }
    }).catch((e) => reject(new Error(e.message || "网络错误")));
  });
}

function uploadImage(filePath) {
  return new Promise((resolve, reject) => {
    window.resolveLocalFileSystemURL(filePath, (entry) => {
      entry.file(async (file) => {
        try {
          const form = new FormData();
          form.append("image", file, "photo.jpg");
          const ctrl = new AbortController();
          const timer = setTimeout(() => ctrl.abort(), UPLOAD_TIMEOUT);
          const res = await fetch(BASE_URL + "/api/upload", { method: "POST", body: form, signal: ctrl.signal });
          clearTimeout(timer);
          const data = await res.json();
          if (!res.ok) { reject(new Error(data.error || "上传失败")); return; }
          if (!data.path) { reject(new Error("上传失败：服务器未返回图片路径")); return; }
          resolve(data);
        } catch (e) { reject(new Error("上传失败")); }
      }, () => reject(new Error("读取照片失败")));
    }, () => reject(new Error("读取照片失败")));
  });
}

function formatTakenAt(date) {
  const pad = (n) => (n < 10 ? "0" + n : "" + n);
  return date.getFullYear() + ":" + pad(date.getMonth() + 1) + ":" + pad(date.getDate()) + " " +
    pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
}

// 压缩：iOS WKWebView 用 canvas 缩放 + JPEG 导出（input file 的 HEIC 已被 iOS 自动转 JPEG）
function compressImage(file, imageConfig) {
  return new Promise((resolve) => {
    const maxDimension = Number(imageConfig.max_dimension);
    const quality = imageConfig.quality <= 1 ? imageConfig.quality : imageConfig.quality / 100;
    const img = new Image();
    const url = URL.createObjectURL(file);
    img.onload = () => {
      let w = img.width, h = img.height;
      if (w > maxDimension || h > maxDimension) {
        const ratio = maxDimension / Math.max(w, h);
        w = Math.round(w * ratio); h = Math.round(h * ratio);
      }
      const canvas = document.createElement("canvas");
      canvas.width = w; canvas.height = h;
      canvas.getContext("2d").drawImage(img, 0, 0, w, h);
      canvas.toBlob((blob) => {
        URL.revokeObjectURL(url);
        const out = blob && blob.size < file.size ? blob : file;
        resolve(new File([out], "photo.jpg", { type: "image/jpeg" }));
      }, "image/jpeg", quality);
    };
    img.onerror = () => { URL.revokeObjectURL(url); resolve(file); };
    img.src = url;
  });
}

function pickPhoto(imageConfig) {
  return new Promise((resolve, reject) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.capture = "";
    input.onchange = async () => {
      const file = input.files && input.files[0];
      if (!file) { reject(new Error("未选择图片")); return; }
      try {
        const compressed = await compressImage(file, imageConfig);
        const upload = await uploadImage(URL.createObjectURL(compressed).replace("blob:", "") || compressed);
        resolve(upload);
      } catch (e) { reject(e); }
    };
    input.click();
  });
}

// uploadImage expects a path resolvable by resolveLocalFileSystemURL; for webview blob files use direct fetch upload
async function pickAndUpload(imageConfig) {
  return new Promise((resolve, reject) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.onchange = async () => {
      const file = input.files && input.files[0];
      if (!file) { reject(new Error("未选择图片")); return; }
      try {
        const compressed = await compressImage(file, imageConfig);
        const form = new FormData();
        form.append("image", compressed, "photo.jpg");
        const res = await fetch(BASE_URL + "/api/upload", { method: "POST", body: form });
        const data = await res.json();
        if (!res.ok || !data.path) { reject(new Error(data.error || "上传失败")); return; }
        const meta = data.metadata || {};
        meta.taken_at = formatTakenAt(new Date());
        resolve({ ...data, metadata: meta });
      } catch (e) { reject(new Error("上传失败")); }
    };
    input.click();
  });
}

const api = {
  BASE_URL,
  request,
  getConfig: () => request("/api/config"),
  getStats: () => request("/api/stats"),
  deleteFood: (id) => request("/api/foods/" + id, "DELETE"),
  getFoods: (page, limit, search, today) => {
    let qs = `page=${page}&limit=${limit}`;
    if (search) qs += `&search=${encodeURIComponent(search)}`;
    if (today) qs += `&today=1`;
    return request(`/api/foods?${qs}`);
  },
  getFoodById: (id) => request(`/api/foods/${id}`),
  submitFood: (record) => request("/api/foods", "POST", record),
  updateFoodDetails: (id, fields) => request(`/api/foods/${id}`, "PATCH", { fields }),
  addComment: (id, comment) => request(`/api/foods/${id}`, "PATCH", { comment }),
  getCategories: () => request("/api/categories"),
  pickAndUpload,
  imageUrl: (path) => (path && path.indexOf("http") === 0 ? path : BASE_URL + path),
};
