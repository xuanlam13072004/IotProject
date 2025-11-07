const express = require('express');
const router = express.Router();
const { controlDevice } = require('../controllers/controlController');
const { pollCommands, ackCommand } = require('../controllers/controlController');
const verifyDeviceSignature = require('../middleware/verifyDeviceSignature');
const { authenticate } = require('../middleware/auth');
const requireModuleControl = require('../middleware/requireModuleControl');

// POST /api/devices/:deviceId/control
// Body: { action: {...} }
router.post('/devices/:deviceId/control', authenticate, requireModuleControl('deviceId'), controlDevice);

// GET /api/devices/:deviceId/commands
// Devices poll this endpoint to retrieve pending commands (and mark them sent).
router.get('/devices/:deviceId/commands', verifyDeviceSignature, pollCommands);

// Device acknowledges a command: POST /api/devices/:deviceId/commands/:commandId/ack
router.post('/devices/:deviceId/commands/:commandId/ack', verifyDeviceSignature, ackCommand);

module.exports = router;
