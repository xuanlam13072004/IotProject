const express = require('express');
const router = express.Router();
const { createDevice, getLatestData } = require('../controllers/deviceController');
const { authenticate } = require('../middleware/auth');
const adminOnly = require('../middleware/adminOnly');

// POST /api/devices (admin) - register a device and its secretKey
router.post('/devices', authenticate, adminOnly, createDevice);

// GET /api/devices/:deviceId/data/latest - fetch latest sensor data
router.get('/devices/:deviceId/data/latest', authenticate, getLatestData);

module.exports = router;
