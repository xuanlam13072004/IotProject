const mongoose = require('mongoose');

const deviceSchema = new mongoose.Schema(
    {
        deviceId: { type: String, required: true, unique: true },
        name: { type: String, default: 'Unnamed Device' },
        secretKey: { type: String, required: true },
        isActive: { type: Boolean, default: true }
    },
    { timestamps: true }
);

module.exports = mongoose.model('Device', deviceSchema);
