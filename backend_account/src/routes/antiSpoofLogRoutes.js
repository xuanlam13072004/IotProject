const express = require('express');
const router = express.Router();
const {
    createAntiSpoofLog,
    getAntiSpoofLogs,
    getAntiSpoofStats,
} = require('../controllers/antiSpoofLogController');
const { authenticate } = require('../middleware/auth');

// POST /api/anti-spoof-logs — Log a training session (called by audio server)
router.post('/anti-spoof-logs', createAntiSpoofLog);

// GET /api/anti-spoof-logs — Query history (app, requires auth)
router.get('/anti-spoof-logs', authenticate, getAntiSpoofLogs);

// GET /api/anti-spoof-logs/stats — Summary stats (app, requires auth)
router.get('/anti-spoof-logs/stats', authenticate, getAntiSpoofStats);

module.exports = router;
