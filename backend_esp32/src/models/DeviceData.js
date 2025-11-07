// src/models/DeviceData.js
import mongoose from "mongoose";

const deviceDataSchema = new mongoose.Schema(
    {
        deviceId: {
            type: String,
            required: true,
        },
        data: {
            type: Object,
            required: true, // ESP32 có thể gửi { temp, hum, gas, flame }
        },
    },
    { timestamps: true }
);

export default mongoose.model("DeviceData", deviceDataSchema);
