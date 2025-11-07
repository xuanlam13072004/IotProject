const Device = require('../models/Device');
const { generateHmac } = require('../utils/crypto');

/**
 * Middleware to verify HMAC signature from device.
 * Expects header 'x-signature' containing hex HMAC over the JSON body (or raw body when available).
 */
module.exports = async function verifyDeviceSignature(req, res, next) {
    try {
        const deviceId = req.params.deviceId || req.params.id;
        const signature = req.headers['x-signature'] || req.headers['X-Signature'];

        const rawBody = typeof req.rawBody === 'string' ? req.rawBody : undefined;
        const parsedBody = req.body;
        const payloadStringified = JSON.stringify(parsedBody);

        if (!signature) return res.status(401).json({ error: 'Missing signature' });

        const device = await Device.findOne({ deviceId });
        if (!device) return res.status(404).json({ error: 'Device not found' });

        const expectedFromRaw = rawBody ? generateHmac(device.secretKey, rawBody) : null;
        const expectedFromParsed = generateHmac(device.secretKey, payloadStringified);

        if (signature !== expectedFromRaw && signature !== expectedFromParsed) {
            return res.status(403).json({ error: 'Invalid signature' });
        }

        req.device = device;
        next();
    } catch (err) {
        console.error('verifyDeviceSignature error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
