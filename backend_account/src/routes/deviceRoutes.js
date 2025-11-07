const express = require('express');
const router = express.Router();
const { createDevice } = require('../controllers/deviceController');
const { authenticate } = require('../middleware/auth');
const adminOnly = require('../middleware/adminOnly');

// POST /api/devices (admin) - register a device and its secretKey
router.post('/devices', authenticate, adminOnly, createDevice);

module.exports = router;
