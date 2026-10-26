<template>
  <view class="page">
    <view class="form-item">
      <text class="label">名称</text>
      <input class="input" v-model="form.name" placeholder="食物名称" />
    </view>
    <view class="form-item">
      <text class="label">品牌</text>
      <input class="input" v-model="form.brand_name" placeholder="品牌（可选）" />
    </view>
    <view class="form-item">
      <text class="label">原价</text>
      <input class="input" type="digit" v-model="form.priceOriginal" placeholder="可空" />
    </view>
    <view class="form-item">
      <text class="label">折扣价</text>
      <input class="input" type="digit" v-model="form.priceDiscount" placeholder="可空" />
    </view>
    <view class="form-item">
      <text class="label">类别</text>
      <input class="input" v-model="form.categoriesText" placeholder="用逗号分隔" />
    </view>
    <view class="form-item">
      <text class="label">原料</text>
      <input class="input" v-model="form.ingredientsText" placeholder="用逗号分隔" />
    </view>
    <view class="actions">
      <view class="btn save" @click="save">保存</view>
      <view class="btn cancel" @click="back">取消</view>
    </view>
  </view>
</template>

<script>
const api = require('../../common/api.js');

export default {
  data() {
    return {
      id: null,
      form: {
        name: '', brand_name: '',
        priceOriginal: '', priceDiscount: '',
        categoriesText: '', ingredientsText: '',
      },
    };
  },
  onLoad(options) {
    this.id = Number(options.id) || null;
  },
  async onReady() {
    if (!this.id) return;
    try {
      const food = await api.getFoodById(this.id);
      const p = Array.isArray(food.price) ? food.price : [food.price, null];
      this.form = {
        name: food.name || '',
        brand_name: food.brand_name || '',
        priceOriginal: p[0] != null ? String(p[0]) : '',
        priceDiscount: p[1] != null ? String(p[1]) : '',
        categoriesText: (food.categories || []).join(','),
        ingredientsText: (food.ingredients || []).join(','),
      };
    } catch (e) {
      uni.showToast({ title: '加载失败', icon: 'none' });
    }
  },
  methods: {
    splitList(text) {
      return (text || '').split(/[,，、]/).map(s => s.trim()).filter(Boolean);
    },
    async save() {
      const f = this.form;
      if (!f.name.trim()) { uni.showToast({ title: '请输入名称', icon: 'none' }); return; }
      const price = [
        f.priceOriginal.trim() === '' ? null : Number(f.priceOriginal),
        f.priceDiscount.trim() === '' ? null : Number(f.priceDiscount),
      ];
      if (price[0] != null && isNaN(price[0])) { uni.showToast({ title: '原价格式不对', icon: 'none' }); return; }
      if (price[1] != null && isNaN(price[1])) { uni.showToast({ title: '折扣价格式不对', icon: 'none' }); return; }
      uni.showLoading({ title: '保存中' });
      try {
        await api.updateFoodDetails(this.id, {
          name: f.name.trim(),
          brand_name: f.brand_name.trim(),
          price,
          categories: this.splitList(f.categoriesText),
          ingredients: this.splitList(f.ingredientsText),
        });
        uni.hideLoading();
        uni.showToast({ title: '已保存', icon: 'success' });
        setTimeout(() => uni.navigateBack(), 600);
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: (e && e.message) || '保存失败', icon: 'none' });
      }
    },
    back() { uni.navigateBack(); },
  },
};
</script>

<style>
.page { min-height: 100vh; background: #F5F5F5; padding: 24rpx; box-sizing: border-box; }
.form-item { background: #fff; border-radius: 12rpx; padding: 20rpx 24rpx; margin-bottom: 16rpx; display: flex; align-items: center; }
.label { width: 140rpx; color: #666; font-size: 28rpx; }
.input { flex: 1; font-size: 28rpx; }
.actions { display: flex; gap: 24rpx; margin-top: 40rpx; }
.btn { flex: 1; text-align: center; padding: 22rpx 0; border-radius: 12rpx; font-size: 30rpx; }
.btn.save { background: #66508f; color: #fff; }
.btn.cancel { background: #eee; }
</style>
