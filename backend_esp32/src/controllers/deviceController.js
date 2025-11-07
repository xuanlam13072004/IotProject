// src/controllers/deviceController.js
import DeviceData from "../models/DeviceData.js";

/**
 * Nhận dữ liệu cảm biến từ ESP32 và lưu vào MongoDB
 */
export const receiveDeviceData = async (req, res) => {
    try {
        const device = req.device; // từ middleware verifySignature
        const data = req.body;

        if (!data || Object.keys(data).length === 0) {
            return res.status(400).json({ error: "Missing data payload" });
        }

        // Lưu dữ liệu vào MongoDB
        const newData = await DeviceData.create({
            deviceId: device.deviceId,
            data,
        });

        res.status(201).json({
            message: "Data received successfully",
            saved: newData,
        });
    } catch (error) {
        console.error("Error saving device data:", error);
        res.status(500).json({ error: "Server error" });
    }
};
