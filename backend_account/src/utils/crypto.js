const crypto = require('crypto');

/**
 * Generate HMAC-SHA256 hex digest for the given data string
 * @param {string} secretKey
 * @param {string} data
 */
function generateHmac(secretKey, data) {
    return crypto.createHmac('sha256', secretKey).update(data).digest('hex');
}

module.exports = { generateHmac };
