const BASE_URL = "https://myfood-worker.keiyokaze.workers.dev";
const UPLOAD_TIMEOUT = 90000;

function request(path, method = "GET", data = null) {
  return new Promise((resolve, reject) => {
    uni.request({
      url: BASE_URL + path,
      method,
      data,
      header: { "Content-Type": "application/json" },
      timeout: 20000,
      success: (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(res.data);
        else reject(new Error((res.data && res.data.error) || "请求失败 HTTP " + res.statusCode));
      },
      fail: (err) => reject(new Error((err.errMsg || "网络错误"))),
    });
  });
}

function uploadImage(filePath) {
  return new Promise((resolve, reject) => {
    uni.uploadFile({
      url: BASE_URL + "/api/upload",
      filePath,
      name: "image",
      timeout: UPLOAD_TIMEOUT,
      success: (res) => {
        try {
          const data = JSON.parse(res.data);
          if (res.statusCode < 200 || res.statusCode >= 300) {
            reject(new Error(data.error || "上传失败"));
            return;
          }
          if (!data.path) reject(new Error("上传失败：服务器未返回图片路径"));
          else resolve(data);
        } catch (e) { reject(new Error("上传失败：无法解析响应")); }
      },
      fail: (err) => reject(new Error(err.errMsg || "上传失败")),
    });
  });
}

function formatTakenAt(date) {
  const pad = (n) => (n < 10 ? "0" + n : "" + n);
  return date.getFullYear() + ":" + pad(date.getMonth() + 1) + ":" + pad(date.getDate()) + " " +
    pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
}

// 选择图片 → 压缩 → 上传（iOS 端照片来自相册/相机，拍摄时间用上传时刻）
function pickAndUpload(imageConfig) {
  return new Promise((resolve, reject) => {
    uni.chooseImage({
      count: 1,
      sizeType: ["compressed"],
      sourceType: ["album", "camera"],
      success: (res) => {
        const filePath = res.tempFilePaths && res.tempFilePaths[0];
        if (!filePath) { reject(new Error("未选择图片")); return; }
        uni.getImageInfo({
          src: filePath,
          success: (info) => {
            const maxDimension = Number(imageConfig.max_dimension);
            let w = info.width, h = info.height;
            if (w > maxDimension || h > maxDimension) {
              const ratio = maxDimension / Math.max(w, h);
              w = Math.round(w * ratio); h = Math.round(h * ratio);
            }
            uni.compressImage({
              src: filePath,
              quality: imageConfig.quality <= 1 ? imageConfig.quality * 100 : imageConfig.quality,
              compressedWidth: w,
              compressedHeight: h,
              success: (c) => finishUpload(c.tempFilePath || filePath),
              fail: () => finishUpload(filePath),
            });
          },
          fail: () => finishUpload(filePath),
        });
        function finishUpload(path) {
          uploadImage(path).then((r) => {
            const meta = r.metadata || {};
            meta.taken_at = formatTakenAt(new Date());
            r.metadata = meta;
            resolve(r);
          }).catch(reject);
        }
      },
      fail: () => reject(new Error("未选择图片")),
    });
  });
}

function getConfig() { return request("/api/config"); }
function getStats() { return request("/api/stats"); }
function deleteFood(id) { return request("/api/foods/" + id, "DELETE"); }
function getFoods(page, limit, search, today) {
  let qs = `page=${page}&limit=${limit}`;
  if (search) qs += `&search=${encodeURIComponent(search)}`;
  if (today) qs += `&today=1`;
  return request(`/api/foods?${qs}`);
}
function getFoodsByCategory(parentName, limit) { return request(`/api/foods?category=${encodeURIComponent(parentName)}&limit=${limit}`); }
function submitFood(record) { return request("/api/foods", "POST", record); }
function updateFoodDetails(id, fields) { return request(`/api/foods/${id}`, "PATCH", { fields }); }
function addComment(id, comment) { return request(`/api/foods/${id}`, "PATCH", { comment }); }
function getFoodById(id) { return request(`/api/foods/${id}`); }
function searchIngredients(q, limit) { return request(`/api/ingredients?search=${encodeURIComponent(q)}&limit=${limit}`); }
function addIngredient(name) { return request("/api/ingredients", "POST", { name }); }
function getCategories() { return request("/api/categories"); }

module.exports = {
  BASE_URL, getConfig, getStats, getFoods, getFoodById, deleteFood, getFoodsByCategory,
  submitFood, updateFoodDetails, addComment, searchIngredients, addIngredient,
  getCategories, uploadImage, pickAndUpload, formatTakenAt,
};
