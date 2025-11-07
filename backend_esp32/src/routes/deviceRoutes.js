// src/routes/deviceRoutes.js
import express from "express";
import { verifySignature } from "../middleware/verifySignature.js";
import { receiveDeviceData } from "../controllers/deviceController.js";

const router = express.Router();

// ESP32 gửi dữ liệu cảm biến
router.post("/devices/:id/data", verifySignature, receiveDeviceData);

export default router;
