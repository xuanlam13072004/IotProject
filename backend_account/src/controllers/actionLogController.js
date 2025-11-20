// Controller for action log history
const ActionLog = require('../models/ActionLog');

// GET /api/action-logs
// Query params: deviceId, actionType, userId, username, source, startDate, endDate, limit, page
module.exports.getActionLogs = async (req, res) => {
    try {
        const {
            deviceId,
            actionType,
            userId,
            username,
            source,
            startDate,
            endDate,
            limit = 50,
            page = 1
        } = req.query;

        // Build query filter
        const filter = {};

        if (deviceId) {
            filter.deviceId = deviceId;
        }

        if (actionType) {
            filter.actionType = actionType;
        }

        if (userId) {
            filter['performedBy.userId'] = userId;
        }

        if (username) {
            filter['performedBy.username'] = { $regex: username, $options: 'i' };
        }

        if (source) {
            filter['performedBy.source'] = source;
        }

        // Date range filter
        if (startDate || endDate) {
            filter.createdAt = {};
            if (startDate) {
                filter.createdAt.$gte = new Date(startDate);
            }
            if (endDate) {
                filter.createdAt.$lte = new Date(endDate);
            }
        }

        // Pagination
        const skip = (parseInt(page) - 1) * parseInt(limit);
        const limitNum = parseInt(limit);

        // Execute query
        const logs = await ActionLog.find(filter)
            .sort({ createdAt: -1 })
            .skip(skip)
            .limit(limitNum)
            .populate('performedBy.userId', 'username email role')
            .lean();

        // Get total count
        const total = await ActionLog.countDocuments(filter);

        return res.json({
            logs,
            pagination: {
                page: parseInt(page),
                limit: limitNum,
                total,
                totalPages: Math.ceil(total / limitNum)
            }
        });
    } catch (err) {
        console.error('getActionLogs error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// GET /api/action-logs/stats
// Get statistics about actions (e.g., count by actionType, by user, by device)
module.exports.getActionStats = async (req, res) => {
    try {
        const { deviceId, startDate, endDate } = req.query;

        // Build match filter
        const matchFilter = {};
        if (deviceId) {
            matchFilter.deviceId = deviceId;
        }
        if (startDate || endDate) {
            matchFilter.createdAt = {};
            if (startDate) {
                matchFilter.createdAt.$gte = new Date(startDate);
            }
            if (endDate) {
                matchFilter.createdAt.$lte = new Date(endDate);
            }
        }

        // Aggregation pipeline
        const stats = await ActionLog.aggregate([
            { $match: matchFilter },
            {
                $facet: {
                    byActionType: [
                        { $group: { _id: '$actionType', count: { $sum: 1 } } },
                        { $sort: { count: -1 } }
                    ],
                    bySource: [
                        { $group: { _id: '$performedBy.source', count: { $sum: 1 } } },
                        { $sort: { count: -1 } }
                    ],
                    byStatus: [
                        { $group: { _id: '$result.status', count: { $sum: 1 } } },
                        { $sort: { count: -1 } }
                    ],
                    byDevice: [
                        { $group: { _id: '$deviceId', count: { $sum: 1 } } },
                        { $sort: { count: -1 } }
                    ],
                    totalActions: [
                        { $count: 'total' }
                    ]
                }
            }
        ]);

        return res.json({
            stats: stats[0],
            period: {
                startDate: startDate || 'all',
                endDate: endDate || 'now'
            }
        });
    } catch (err) {
        console.error('getActionStats error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// GET /api/action-logs/:id
// Get single action log by ID
module.exports.getActionLogById = async (req, res) => {
    try {
        const { id } = req.params;

        const log = await ActionLog.findById(id)
            .populate('performedBy.userId', 'username email role')
            .lean();

        if (!log) {
            return res.status(404).json({ error: 'Action log not found' });
        }

        return res.json(log);
    } catch (err) {
        console.error('getActionLogById error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// DELETE /api/action-logs (Admin only)
// Delete old logs before a certain date
module.exports.deleteOldLogs = async (req, res) => {
    try {
        const { beforeDate } = req.body;

        if (!beforeDate) {
            return res.status(400).json({ error: 'beforeDate is required' });
        }

        const result = await ActionLog.deleteMany({
            createdAt: { $lt: new Date(beforeDate) }
        });

        return res.json({
            message: 'Old logs deleted successfully',
            deletedCount: result.deletedCount
        });
    } catch (err) {
        console.error('deleteOldLogs error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
