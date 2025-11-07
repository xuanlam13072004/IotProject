// src/models/Device.js
import mongoose from "mongoose";

const deviceSchema = new mongoose.Schema(
    {
        deviceId: {
            type: String,
            required: true,
            unique: true,
        },
        name: {
            type: String,
            default: "Unnamed Device",
        },
        secretKey: {
            type: String,
            required: true, // ESP32 sẽ dùng key này để tạo HMAC
        },
        isActive: {
            type: Boolean,
            default: true,
        },
    },
    { timestamps: true }
);

export default mongoose.model("Device", deviceSchema);
