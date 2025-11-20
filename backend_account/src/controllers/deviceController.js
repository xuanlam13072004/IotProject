const Device = require('../models/Device');
const DeviceData = require('../models/DeviceData');

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

/**
 * GET /api/devices/:deviceId/data/latest
 * Fetch the most recent sensor data record from MongoDB
 */
module.exports.getLatestData = async (req, res) => {
    try {
        const { deviceId } = req.params;

        // Find the most recent record for this device
        const latest = await DeviceData.findOne({ deviceId })
            .sort({ createdAt: -1 })
            .limit(1)
            .lean();

        if (!latest) {
            return res.status(404).json({ error: 'No data found for this device' });
        }

        // Fetch device info to get mute state
        const device = await Device.findOne({ deviceId }).lean();

        // Extract data fields with defaults
        const {
            temperature = 0,
            humidity = 0,
            gasValue = 0,
            fireAlert = false,
            awningOpen = false,
            doorOpen = false,
            raining = false,
            awningAutoMode = false,
        } = latest.data || {};

        return res.json({
            temperature,
            humidity,
            gasValue,
            fireAlert,
            awningOpen,
            doorOpen,
            raining,
            awningAutoMode,
            timestamp: latest.createdAt,
            mutedSensors: device?.mutedSensors || [],
            muteEndsAt: device?.muteEndsAt || null,
        });
    } catch (err) {
        console.error('getLatestData error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
