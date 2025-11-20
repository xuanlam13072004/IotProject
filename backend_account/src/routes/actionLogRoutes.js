const express = require('express');
const router = express.Router();
const {
    getActionLogs,
    getActionStats,
    getActionLogById,
    deleteOldLogs
} = require('../controllers/actionLogController');
const { authenticate } = require('../middleware/auth');
const adminOnly = require('../middleware/adminOnly');

// GET /api/action-logs - Get action logs with filters
router.get('/action-logs', authenticate, getActionLogs);

// GET /api/action-logs/stats - Get statistics
router.get('/action-logs/stats', authenticate, getActionStats);

// GET /api/action-logs/:id - Get single log by ID
router.get('/action-logs/:id', authenticate, getActionLogById);

// DELETE /api/action-logs - Delete old logs (Admin only)
router.delete('/action-logs', authenticate, adminOnly, deleteOldLogs);

module.exports = router;
