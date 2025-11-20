const mongoose = require('mongoose');

// Chi tiết permissions cho từng thiết bị/tính năng
const PermissionsSchema = new mongoose.Schema({
    // Thiết bị vật lý
    door: {
        view: { type: Boolean, default: true },
        open: { type: Boolean, default: false },
        close: { type: Boolean, default: false }
    },
    awning: {
        view: { type: Boolean, default: true },
        open: { type: Boolean, default: false },
        close: { type: Boolean, default: false },
        setMode: { type: Boolean, default: false }  // auto/manual
    },
    // Quản lý báo động
    alarm: {
        view: { type: Boolean, default: true },
        snooze: { type: Boolean, default: false },      // Tạm hoãn báo động
        cancelSnooze: { type: Boolean, default: false }, // Kích hoạt lại (admin)
        snoozeAll: { type: Boolean, default: false },    // Tắt tất cả
        snoozeFire: { type: Boolean, default: false },   // Chỉ tắt lửa
        snoozeGas: { type: Boolean, default: false }     // Chỉ tắt gas
    },
    // Dữ liệu cảm biến
    sensors: {
        viewTemperature: { type: Boolean, default: true },
        viewHumidity: { type: Boolean, default: true },
        viewGas: { type: Boolean, default: true },
        viewFire: { type: Boolean, default: true }
    }
}, { _id: false });

const AccountSchema = new mongoose.Schema({
    username: { type: String, required: true, unique: true },
    passwordHash: { type: String, required: true },
    role: { type: String, enum: ['admin', 'user', 'guest'], required: true },
    permissions: { type: PermissionsSchema, default: {} },
    modules: { type: [Object], default: [] },  // Giữ lại cho tương thích ngược
    createdAt: { type: Date, default: Date.now }
});

// Method để kiểm tra quyền
AccountSchema.methods.hasPermission = function (category, action) {
    if (this.role === 'admin') return true; // Admin có tất cả quyền
    if (!this.permissions || !this.permissions[category]) return false;
    return this.permissions[category][action] === true;
};

module.exports = mongoose.model('Account', AccountSchema);
