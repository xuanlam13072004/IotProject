// src/middleware/verifySignature.js
import Device from "../models/Device.js";
import { generateHmac } from "../utils/crypto.js";

/**
 * Middleware xác thực HMAC từ ESP32
 */
export const verifySignature = async (req, res, next) => {
    try {
        const deviceId = req.params.id;
        const signature = req.headers["x-signature"] || req.headers["X-Signature"];

        // Raw body captured by express.json verify option in app.js
        const rawBody = typeof req.rawBody === 'string' ? req.rawBody : undefined;
        const parsedBody = req.body;
        const payloadStringified = JSON.stringify(parsedBody);

        console.log(`🔐 Incoming signature: ${signature}`);
        console.log(`📝 rawBody: ${rawBody}`);
        console.log(`🧾 parsedBody stringified: ${payloadStringified}`);

        if (!signature) {
            return res.status(401).json({ error: "Missing signature" });
        }

        const device = await Device.findOne({ deviceId });
        if (!device) {
            return res.status(404).json({ error: "Device not found" });
        }

        // Calculate HMAC over rawBody (if available) and over stringified parsed body
        const expectedFromRaw = rawBody ? generateHmac(device.secretKey, rawBody) : null;
        const expectedFromParsed = generateHmac(device.secretKey, payloadStringified);

        console.log(`🔑 expectedFromRaw: ${expectedFromRaw}`);
        console.log(`🔑 expectedFromParsed: ${expectedFromParsed}`);

        // Accept if any match (helps debugging). In production you may restrict to one deterministic method.
        if (signature !== expectedFromRaw && signature !== expectedFromParsed) {
            console.warn('Signature mismatch');
            return res.status(403).json({ error: "Invalid signature" });
        }

        req.device = device;
        next();
    } catch (error) {
        console.error("Signature verification error:", error);
        res.status(500).json({ error: "Server error" });
    }
};
