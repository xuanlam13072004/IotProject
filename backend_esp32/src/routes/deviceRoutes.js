// src/routes/deviceRoutes.js
import express from "express";
import { verifySignature } from "../middleware/verifySignature.js";
import { receiveDeviceData } from "../controllers/deviceController.js";

const router = express.Router();

// ESP32 gửi dữ liệu cảm biến
router.post("/devices/:id/data", verifySignature, receiveDeviceData);

// Explicit route for esp32_1 to match device firmware expectations exactly
router.post(
    "/devices/esp32_1/data",
    (req, res, next) => { req.params.id = "esp32_1"; next(); },
    verifySignature,
    receiveDeviceData
);

export default router;
