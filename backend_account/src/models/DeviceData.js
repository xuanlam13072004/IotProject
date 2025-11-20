// backend_account/src/models/DeviceData.js
// Schema for sensor data stored by ESP32 via backend_esp32
const mongoose = require('mongoose');

const deviceDataSchema = new mongoose.Schema(
    {
        deviceId: {
            type: String,
            required: true,
            index: true,
        },
        data: {
            type: Object,
            required: true,
        },
    },
    { timestamps: true }
);

// Index for fast retrieval of latest record per device
deviceDataSchema.index({ deviceId: 1, createdAt: -1 });

module.exports = mongoose.model('DeviceData', deviceDataSchema);
