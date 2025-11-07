// src/utils/crypto.js
import crypto from "crypto";

/**
 * Tạo chữ ký HMAC-SHA256
 * @param {string} secretKey - khóa bí mật của thiết bị
 * @param {string} data - chuỗi JSON (payload)
 */
export const generateHmac = (secretKey, data) => {
    return crypto.createHmac("sha256", secretKey).update(data).digest("hex");
};
