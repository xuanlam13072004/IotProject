const Device = require('../models/Device');

module.exports.createDevice = async (req, res) => {
    try {
        const { deviceId, name, secretKey } = req.body || {};
        if (!deviceId || !secretKey) return res.status(400).json({ error: 'deviceId and secretKey are required' });

        const existing = await Device.findOne({ deviceId });
        if (existing) return res.status(409).json({ error: 'Device already exists' });

        const d = new Device({ deviceId, name, secretKey });
        await d.save();
        return res.status(201).json({ deviceId: d.deviceId, name: d.name, _id: d._id });
    } catch (err) {
        console.error('createDevice error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
