const AntiSpoofLog = require('../models/AntiSpoofLog');

// POST /api/anti-spoof-logs — Create a new training log entry
async function createAntiSpoofLog(req, res) {
    try {
        const {
            ownerId,
            action,
            numBonafide,
            numSpoofSimulated,
            numSpoofReal,
            numSpoofRealNew,
            savedSpoofFiles,
            epochs,
            finalLoss,
            source,
            metadata,
        } = req.body;

        if (!ownerId || !action) {
            return res.status(400).json({ error: 'ownerId and action are required' });
        }

        const log = new AntiSpoofLog({
            ownerId,
            action,
            numBonafide: numBonafide || 0,
            numSpoofSimulated: numSpoofSimulated || 0,
            numSpoofReal: numSpoofReal || 0,
            numSpoofRealNew: numSpoofRealNew || 0,
            savedSpoofFiles: savedSpoofFiles || [],
            epochs: epochs || 0,
            finalLoss: finalLoss ?? null,
            source: source || 'api',
            metadata: metadata || {},
        });

        await log.save();
        return res.status(201).json(log);
    } catch (err) {
        return res.status(500).json({ error: err.message });
    }
}

// GET /api/anti-spoof-logs?ownerId=...&limit=...&page=...
async function getAntiSpoofLogs(req, res) {
    try {
        const { ownerId, action, limit = 50, page = 1 } = req.query;
        const filter = {};
        if (ownerId) filter.ownerId = ownerId;
        if (action) filter.action = action;

        const skip = (Math.max(1, parseInt(page, 10)) - 1) * parseInt(limit, 10);
        const logs = await AntiSpoofLog.find(filter)
            .sort({ createdAt: -1 })
            .skip(skip)
            .limit(parseInt(limit, 10));

        const total = await AntiSpoofLog.countDocuments(filter);

        return res.json({
            logs,
            total,
            page: parseInt(page, 10),
            totalPages: Math.ceil(total / parseInt(limit, 10)),
        });
    } catch (err) {
        return res.status(500).json({ error: err.message });
    }
}

// GET /api/anti-spoof-logs/stats?ownerId=...
async function getAntiSpoofStats(req, res) {
    try {
        const { ownerId } = req.query;
        const match = {};
        if (ownerId) match.ownerId = ownerId;

        const stats = await AntiSpoofLog.aggregate([
            { $match: match },
            {
                $group: {
                    _id: '$ownerId',
                    totalSessions: { $sum: 1 },
                    totalSpoofReal: { $sum: '$numSpoofReal' },
                    totalSpoofSimulated: { $sum: '$numSpoofSimulated' },
                    totalBonafide: { $sum: '$numBonafide' },
                    avgFinalLoss: { $avg: '$finalLoss' },
                    lastTrainedAt: { $max: '$createdAt' },
                },
            },
            { $sort: { lastTrainedAt: -1 } },
        ]);

        return res.json({ stats });
    } catch (err) {
        return res.status(500).json({ error: err.message });
    }
}

module.exports = { createAntiSpoofLog, getAntiSpoofLogs, getAntiSpoofStats };
