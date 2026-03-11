const express = require('express');
const http = require('http');
const router = express.Router();
const { controlDevice, logDeviceAction, controlDeviceFromVoice } = require('../controllers/controlController');
const { pollCommands, ackCommand } = require('../controllers/controlController');
const verifyDeviceSignature = require('../middleware/verifyDeviceSignature');
const { authenticate } = require('../middleware/auth');
const requireModuleControl = require('../middleware/requireModuleControl');
const { checkActionPermission } = require('../middleware/checkPermission');

// Internal bridge for voice server -> account backend command queue
router.post('/voice/commands', controlDeviceFromVoice);

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

// --- Route cho ESP32-CAM gửi lệnh (dùng chung secret HMAC với esp32_1) ---
// ESP32-CAM POST /api/devices/esp32_1/commands/from-camera
// Body: { "action": "open_door" }
router.post(
    '/devices/esp32_1/commands/from-camera',
    (req, res, next) => {
        // Bắt buộc deviceId = esp32_1 để lệnh được queue cho đúng thiết bị cửa chính
        req.params.deviceId = 'esp32_1';
        next();
    },
    verifyDeviceSignature,
    // Gắn thông tin "ảo" để controlController log lại nguồn là esp32_cam
    (req, res, next) => {
        req.account = {
            id: null,
            username: 'esp32_cam'
        };
        next();
    },
    controlDevice
);

// ================= ESP32-CAM SNAPSHOT PROXY =================
// Allows the Flutter app to view the camera from any network via Cloudflare Tunnel.
// GET /api/cam/snapshot
const ESP32_CAM_IP = process.env.ESP32_CAM_IP || '192.168.137.100';
const ESP32_CAM_PORT = parseInt(process.env.ESP32_CAM_PORT || '80', 10);

router.get('/cam/snapshot', authenticate, (req, res) => {
    const camReq = http.get(
        {
            hostname: ESP32_CAM_IP,
            port: ESP32_CAM_PORT,
            path: '/snapshot.jpg',
            timeout: 5000,
        },
        (camRes) => {
            if (camRes.statusCode !== 200) {
                res.status(502).json({ error: 'ESP32-CAM returned ' + camRes.statusCode });
                camRes.resume();
                return;
            }
            res.set({
                'Content-Type': camRes.headers['content-type'] || 'image/jpeg',
                'Cache-Control': 'no-cache, no-store',
            });
            camRes.pipe(res);
        }
    );
    camReq.on('error', () => {
        if (!res.headersSent) {
            res.status(502).json({ error: 'Cannot reach ESP32-CAM' });
        }
    });
    camReq.on('timeout', () => {
        camReq.destroy();
        if (!res.headersSent) {
            res.status(504).json({ error: 'ESP32-CAM timeout' });
        }
    });
});

module.exports = router;