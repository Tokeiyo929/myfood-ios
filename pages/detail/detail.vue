<template>
  <view class="page" v-if="food">
    <image class="hero" v-if="food.image_path" :src="imageUrl(food.image_path)" mode="widthFix" @click="previewImage" />
    <view class="body">
      <view class="name">{{ food.name || '未命名' }}</view>
      <view class="meta" v-if="food.taken_at">{{ food.taken_at }}</view>

      <view class="row" v-if="priceText">
        <text class="label">价格</text><text class="value">{{ priceText }}</text>
      </view>
      <view class="row" v-if="food.brand_name">
        <text class="label">品牌</text><text class="value">{{ food.brand_name }}</text>
      </view>
      <view class="row" v-if="food.categories && food.categories.length">
        <text class="label">类别</text><text class="value">{{ food.categories.join('、') }}</text>
      </view>
      <view class="row" v-if="food.ingredients && food.ingredients.length">
        <text class="label">原料</text><text class="value">{{ food.ingredients.join('、') }}</text>
      </view>
      <view class="row" v-if="food.flavors && food.flavors.length">
        <text class="label">味道</text><text class="value">{{ flavorText }}</text>
      </view>

      <view class="comments" v-if="comments.length">
        <view class="section-title">评论</view>
        <view class="comment-item" v-for="(c, i) in comments" :key="i">
          <text>{{ c }}</text>
        </view>
      </view>

      <view class="actions">
        <view class="btn edit" @click="goEdit">编辑</view>
        <view class="btn del" @click="confirmDelete">删除</view>
      </view>
    </view>
  </view>
</template>

<script>
const api = require('../../common/api.js');

export default {
  data() {
    return { id: null, food: null };
  },
  computed: {
    priceText() {
      const p = this.food && this.food.price;
      if (Array.isArray(p)) {
        const parts = [];
        if (p[0] != null) parts.push('原价 ' + p[0]);
        if (p[1] != null) parts.push('折后 ' + p[1]);
        return parts.join(' / ');
      }
      if (p != null) return String(p);
      return '';
    },
    flavorText() {
      const FLAVOR_DEFAULTS = { 甜: 50, 咸: 50, 酸: 50, 辣: 50, 苦: 50, 鲜: 50, 淡: 50, 油腻: 50 };
      return (this.food.flavors || [])
        .filter(f => f && f.name && f.value != null && f.value !== FLAVOR_DEFAULTS[f.name])
        .map(f => (f.value < 50 ? '不' : f.value > 70 ? '太' : '微') + f.name)
        .join('、');
    },
    comments() { return (this.food && this.food.comment) || []; },
  },
  onLoad(options) {
    this.id = Number(options.id);
  },
  onShow() {
    if (this.id) this.loadFood();
  },
  methods: {
    imageUrl(path) {
      return path.indexOf('http') === 0 ? path : api.BASE_URL + path;
    },
    async loadFood() {
      try {
        this.food = await api.getFoodById(this.id);
      } catch (e) {
        uni.showToast({ title: '加载失败', icon: 'none' });
      }
    },
    previewImage() {
      if (this.food.image_path) {
        uni.previewImage({ urls: [this.imageUrl(this.food.image_path)] });
      }
    },
    goEdit() {
      uni.navigateTo({ url: '/pages/edit/edit?id=' + this.id });
    },
    confirmDelete() {
      uni.showModal({
        title: '删除记录',
        content: '确定删除这条记录吗？',
        success: async (res) => {
          if (!res.confirm) return;
          try {
            await api.deleteFood(this.id);
            uni.showToast({ title: '已删除', icon: 'success' });
            setTimeout(() => uni.navigateBack(), 600);
          } catch (e) {
            uni.showToast({ title: (e && e.message) || '删除失败', icon: 'none' });
          }
        },
      });
    },
  },
};
</script>

<style>
.page { min-height: 100vh; background: #F5F5F5; }
.hero { width: 100%; }
.body { padding: 24rpx; }
.name { font-size: 40rpx; font-weight: bold; }
.meta { font-size: 24rpx; color: #999; margin-top: 8rpx; }
.row { display: flex; margin-top: 20rpx; }
.label { width: 120rpx; color: #999; font-size: 28rpx; }
.value { flex: 1; font-size: 28rpx; }
.section-title { font-size: 32rpx; font-weight: bold; margin: 32rpx 0 8rpx; }
.comment-item { background: #fff; border-radius: 12rpx; padding: 16rpx; margin-bottom: 12rpx; font-size: 28rpx; }
.comments { margin-top: 8rpx; }
.actions { display: flex; gap: 24rpx; margin-top: 48rpx; }
.btn { flex: 1; text-align: center; padding: 22rpx 0; border-radius: 12rpx; font-size: 30rpx; }
.btn.edit { background: #66508f; color: #fff; }
.btn.del { background: #eee; color: #c0392b; }
</style>
