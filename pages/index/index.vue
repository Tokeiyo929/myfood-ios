<template>
  <view class="page">
    <view class="today-scroll">
      <!-- 拍照/相册按钮 -->
      <view class="actions">
        <view class="action-btn" @click="chooseImage">
          <text class="action-icon">🖼</text>
          <text class="action-text">从相册选</text>
        </view>
        <view class="action-btn" @click="takePhoto">
          <text class="action-icon">📷</text>
          <text class="action-text">拍照</text>
        </view>
      </view>

      <!-- 今日记录列表 -->
      <view class="section-title">今日记录</view>
      <view v-if="todayRecords.length === 0" class="empty">今天还没有记录</view>
      <view class="record-card" v-for="rec in todayRecords" :key="rec.id" @click="openDetail(rec.id)">
        <image class="record-img" v-if="rec.image_path" :src="imageUrl(rec.image_path)" mode="aspectFill" />
        <view class="record-body">
          <view class="record-name">{{ rec.name || '未命名' }}</view>
          <view class="record-time">{{ rec.taken_at || rec.create_at }}</view>
        </view>
        <view class="record-comment-btn" @click.stop="openComment(rec)">💬</view>
      </view>
    </view>

    <!-- 评论弹层 -->
    <view class="mask" v-if="commentingId !== null" @click="closeComment">
      <view class="comment-panel" @click.stop>
        <view class="cp-title">评论</view>
        <scroll-view scroll-y class="cp-list">
          <view class="cp-item" v-for="(c, i) in comments" :key="i">
            <text>{{ c }}</text>
          </view>
        </scroll-view>
        <textarea class="cp-input" v-model="commentInput" placeholder="写评论..." :maxlength="500" />
        <view class="cp-actions">
          <view class="cp-btn cancel" @click="closeComment">取消</view>
          <view class="cp-btn save" @click="saveComment">保存</view>
        </view>
      </view>
    </view>
  </view>
</template>

<script>
const api = require('../../common/api.js');

export default {
  data() {
    return {
      settings: null,
      todayRecords: [],
      uploading: false,
      commentingId: null,
      comments: [],
      commentInput: '',
    };
  },
  onShow() {
    if (!this.settings) this.loadConfig();
    else this.loadToday();
  },
  methods: {
    imageUrl(path) {
      if (!path) return '';
      return path.indexOf('http') === 0 ? path : api.BASE_URL + path;
    },
    async loadConfig() {
      try {
        this.settings = await api.getConfig();
        this.loadToday();
      } catch (e) {
        uni.showToast({ title: '配置加载失败', icon: 'none' });
      }
    },
    async loadToday() {
      if (!this.settings) return;
      try {
        const result = await api.getFoods(1, this.settings.pagination.max_page_size, '', true);
        this.todayRecords = (result.items || []).map(r => ({ ...r, comments: r.comment || [] }));
      } catch (e) {
        uni.showToast({ title: '今日记录加载失败', icon: 'none' });
      }
    },
    async chooseImage() { await this.saveQuick('album'); },
    async takePhoto() { await this.saveQuick('camera'); },
    async saveQuick() {
      if (this.uploading) { uni.showToast({ title: '上传中', icon: 'none' }); return; }
      if (!this.settings) { uni.showToast({ title: '配置加载中', icon: 'none' }); return; }
      this.uploading = true;
      uni.showLoading({ title: '上传中' });
      try {
        const upload = await api.pickAndUpload(this.settings.image);
        const record = {
          name: '',
          brand_name: '',
          price: null,
          categories: [],
          ingredients: [],
          flavors: [],
          preference: this.settings.preferences.good.value,
          comment: [],
          image_path: upload.path,
          image_metadata: upload.metadata || {},
          client_key: Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10),
        };
        await api.submitFood(record);
        uni.hideLoading();
        uni.showToast({ title: '已保存', icon: 'success' });
        this.uploading = false;
        this.loadToday();
      } catch (e) {
        uni.hideLoading();
        this.uploading = false;
        const msg = (e && e.message) || '保存失败';
        if (msg.indexOf('未选择图片') === -1) uni.showToast({ title: msg, icon: 'none' });
      }
    },
    openDetail(id) {
      uni.navigateTo({ url: '/pages/detail/detail?id=' + id });
    },
    openComment(rec) {
      this.commentingId = rec.id;
      this.comments = rec.comments || [];
      this.commentInput = '';
    },
    closeComment() {
      this.commentingId = null;
      this.commentInput = '';
    },
    async saveComment() {
      const text = (this.commentInput || '').trim();
      if (!text || this.commentingId === null) {
        uni.showToast({ title: '请输入评论', icon: 'none' });
        return;
      }
      const newComments = this.comments.concat([text]);
      uni.showLoading({ title: '保存中' });
      try {
        await api.addComment(this.commentingId, newComments);
        uni.hideLoading();
        this.commentInput = '';
        uni.showToast({ title: '已评论', icon: 'success' });
        this.loadToday();
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: (e && e.message) || '保存失败', icon: 'none' });
      }
    },
  },
};
</script>

<style>
.page { min-height: 100vh; background: #F5F5F5; padding: 24rpx; box-sizing: border-box; }
.actions { display: flex; gap: 24rpx; margin-bottom: 32rpx; }
.action-btn { flex: 1; background: #66508f; border-radius: 16rpx; padding: 32rpx 0; display: flex; flex-direction: column; align-items: center; }
.action-icon { font-size: 48rpx; }
.action-text { color: #fff; font-size: 28rpx; margin-top: 8rpx; }
.section-title { font-size: 32rpx; font-weight: bold; margin: 16rpx 0; }
.empty { color: #999; text-align: center; padding: 60rpx 0; }
.record-card { background: #fff; border-radius: 16rpx; margin-bottom: 16rpx; display: flex; align-items: center; padding: 16rpx; }
.record-img { width: 120rpx; height: 120rpx; border-radius: 12rpx; background: #eee; }
.record-body { flex: 1; margin-left: 20rpx; }
.record-name { font-size: 30rpx; }
.record-time { font-size: 24rpx; color: #999; margin-top: 6rpx; }
.record-comment-btn { padding: 12rpx; font-size: 36rpx; }
.mask { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.5); display: flex; align-items: flex-end; z-index: 100; }
.comment-panel { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 32rpx; box-sizing: border-box; }
.cp-title { font-size: 32rpx; font-weight: bold; margin-bottom: 16rpx; }
.cp-list { max-height: 300rpx; margin-bottom: 16rpx; }
.cp-item { padding: 12rpx 0; border-bottom: 1rpx solid #eee; font-size: 28rpx; }
.cp-input { width: 100%; height: 140rpx; background: #F5F5F5; border-radius: 12rpx; padding: 16rpx; box-sizing: border-box; font-size: 28rpx; }
.cp-actions { display: flex; gap: 24rpx; margin-top: 24rpx; }
.cp-btn { flex: 1; text-align: center; padding: 20rpx 0; border-radius: 12rpx; font-size: 30rpx; }
.cp-btn.cancel { background: #eee; }
.cp-btn.save { background: #66508f; color: #fff; }
</style>
