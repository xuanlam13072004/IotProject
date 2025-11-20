const mongoose = require('mongoose');

const deviceSchema = new mongoose.Schema(
    {
        deviceId: { type: String, required: true, unique: true },
        name: { type: String, default: 'Unnamed Device' },
        secretKey: { type: String, required: true },
        isActive: { type: Boolean, default: true },
        mutedSensors: { type: [String], default: [] },  // ["fire", "gas"] or ["all"]
        muteEndsAt: { type: Date, default: null }
    },
    { timestamps: true }
);

module.exports = mongoose.model('Device', deviceSchema);
