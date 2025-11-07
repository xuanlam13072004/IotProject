const mongoose = require('mongoose');

const ModulePermissionSchema = new mongoose.Schema({
    moduleId: { type: String, required: true },
    canRead: { type: Boolean, default: false },
    canControl: { type: Boolean, default: false }
}, { _id: false });

const AccountSchema = new mongoose.Schema({
    username: { type: String, required: true, unique: true },
    passwordHash: { type: String, required: true },
    role: { type: String, enum: ['admin', 'user', 'guest'], required: true },
    modules: { type: [ModulePermissionSchema], default: [] },
    createdAt: { type: Date, default: Date.now }
});

module.exports = mongoose.model('Account', AccountSchema);
