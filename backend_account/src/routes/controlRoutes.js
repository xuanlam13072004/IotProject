const express = require('express');
const router = express.Router();
const { controlDevice, logDeviceAction } = require('../controllers/controlController');
const { pollCommands, ackCommand } = require('../controllers/controlController');
const verifyDeviceSignature = require('../middleware/verifyDeviceSignature');
const { authenticate } = require('../middleware/auth');
const requireModuleControl = require('../middleware/requireModuleControl');
const { checkActionPermission } = require('../middleware/checkPermission');

// POST /api/devices/:deviceId/control
// Body: { action: {...} }
router.post('/devices/:deviceId/control', authenticate, checkActionPermission, controlDevice);

// GET /api/devices/:deviceId/commands
// Devices poll this endpoint to retrieve pending commands (and mark them sent).
router.get('/devices/:deviceId/commands', verifyDeviceSignature, pollCommands);

// Device acknowledges a command: POST /api/devices/:deviceId/commands/:commandId/ack
router.post('/devices/:deviceId/commands/:commandId/ack', verifyDeviceSignature, ackCommand);

// Device logs an action directly (e.g., keypad password change)
// POST /api/devices/:deviceId/log
router.post('/devices/:deviceId/log', verifyDeviceSignature, logDeviceAction);

// --- Explicit routes for esp32_1 to match device firmware expectations exactly ---
// GET /api/devices/esp32_1/commands (device polling)
router.get(
    '/devices/esp32_1/commands',
    (req, res, next) => { req.params.deviceId = 'esp32_1'; next(); },
    verifyDeviceSignature,
    pollCommands
);

// POST /api/devices/esp32_1/commands (app posts a new command)
router.post(
    '/devices/esp32_1/commands',
    authenticate,
    (req, res, next) => { req.params.deviceId = 'esp32_1'; next(); },
    checkActionPermission,
    controlDevice
);

// POST /api/devices/esp32_1/commands/:commandId/ack (device acknowledges)
router.post(
    '/devices/esp32_1/commands/:commandId/ack',
    (req, res, next) => { req.params.deviceId = 'esp32_1'; next(); },
    verifyDeviceSignature,
    ackCommand
);

// POST /api/devices/esp32_1/log (device logs action)
router.post(
    '/devices/esp32_1/log',
    (req, res, next) => { req.params.deviceId = 'esp32_1'; next(); },
    verifyDeviceSignature,
    logDeviceAction
);

module.exports = router;
