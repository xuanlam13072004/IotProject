// Controller to handle device control requests from authenticated users
const crypto = require('crypto');
const PendingCommand = require('../models/PendingCommand');
const Device = require('../models/Device');
const ActionLog = require('../models/ActionLog');

const ALLOWED_ACTIONS = new Set([
    'open_door',
    'close_door',
    'open_awning',
    'close_awning',
    'set_auto',
    'set_manual',
    'set_snooze',
    'cancel_snooze'
]);

// Human-readable descriptions for each action
const ACTION_DESCRIPTIONS = {
    open_door: 'Open door',
    close_door: 'Close door',
    open_awning: 'Open awning',
    close_awning: 'Close awning',
    set_auto: 'Switch to auto mode',
    set_manual: 'Switch to manual mode',
    set_snooze: 'Snooze alerts',
    cancel_snooze: 'Resume alerts',
    change_password: 'Change password',
    door_open: 'Door opened',
    door_close: 'Door closed',
    alarm_trigger: 'Alarm triggered',
};

// Map raw action names to specific actionType enum values
function resolveActionType(action) {
    switch (action) {
        case 'open_door': return 'door_open';
        case 'close_door': return 'door_close';
        case 'open_awning': return 'control_device';
        case 'close_awning': return 'control_device';
        case 'set_auto': return 'system_mode_change';
        case 'set_manual': return 'system_mode_change';
        case 'set_snooze': return 'set_snooze';
        case 'cancel_snooze': return 'cancel_snooze';
        case 'change_password': return 'change_password';
        default: return 'control_device';
    }
}

async function queueControlCommand({ deviceId, body, performedBy, source }) {
    const action = body.action;
    if (!action) throw new Error('action is required in body');

    if (action === 'set_snooze') {
        const seconds = parseInt(body.seconds) || 300;
        const sensor = body.sensor || 'all';
        const muteEndsAt = new Date(Date.now() + seconds * 1000);

        let mutedSensors = [];
        if (sensor === 'all') {
            mutedSensors = ['all'];
        } else if (sensor === 'fire' || sensor === 'gas') {
            const device = await Device.findOne({ deviceId });
            const current = device?.mutedSensors || [];
            mutedSensors = [...new Set([...current.filter(s => s !== 'all'), sensor])];
        }

        await Device.findOneAndUpdate(
            { deviceId },
            { mutedSensors, muteEndsAt },
            { new: true }
        );
    }

    if (action === 'cancel_snooze') {
        const sensor = body.sensor || 'all';

        let mutedSensors = [];
        if (sensor === 'all') {
            mutedSensors = [];
        } else {
            const device = await Device.findOne({ deviceId });
            const current = device?.mutedSensors || [];
            mutedSensors = current.filter(s => s !== sensor && s !== 'all');
        }

        const muteEndsAt = mutedSensors.length > 0 ? new Date(Date.now() + 300000) : null;

        await Device.findOneAndUpdate(
            { deviceId },
            { mutedSensors, muteEndsAt },
            { new: true }
        );
    }

    const actionObject = {
        name: action,
        ...(body.seconds && { seconds: parseInt(body.seconds) }),
        ...(body.sensor && { sensor: body.sensor })
    };

    const cmd = new PendingCommand({
        deviceId,
        action: actionObject,
        requestedBy: performedBy.userId || undefined,
        requestedByUsername: performedBy.username || undefined,
        status: 'pending'
    });
    await cmd.save();

    // Build clean parameters (exclude redundant 'action' field)
    const cleanParams = {};
    if (body.seconds) cleanParams.seconds = parseInt(body.seconds);
    if (body.sensor) cleanParams.sensor = body.sensor;

    const description = ACTION_DESCRIPTIONS[action] || action;
    // Append sensor info for snooze actions
    let fullDescription = description;
    if (action === 'set_snooze' && body.sensor) {
        const sensorLabel = body.sensor === 'all' ? 'all' : body.sensor === 'fire' ? 'fire' : body.sensor === 'gas' ? 'gas' : body.sensor;
        const duration = body.seconds ? `${Math.round(body.seconds / 60)} min` : '5 min';
        fullDescription = `${description} ${sensorLabel} (${duration})`;
    }

    const actionLog = new ActionLog({
        actionType: resolveActionType(action),
        deviceId,
        performedBy: {
            userId: performedBy.userId || null,
            username: performedBy.username || 'unknown',
            source
        },
        details: {
            action,
            description: fullDescription,
            commandId: cmd._id.toString(),
            ...(Object.keys(cleanParams).length > 0 && { parameters: cleanParams })
        },
        result: {
            status: 'pending',
            message: 'Command queued, awaiting device'
        },
        metadata: {
            timestamp: new Date()
        }
    });
    await actionLog.save();

    return cmd;
}

module.exports.controlDevice = async (req, res) => {
    try {
        const deviceId = req.params.deviceId;
        const body = req.body || {};
        const action = body.action;
        if (!action) return res.status(400).json({ error: 'action is required in body' });

        const cmd = await queueControlCommand({
            deviceId,
            body,
            performedBy: {
                userId: req.account && req.account.id ? req.account.id : null,
                username: req.account && req.account.username ? req.account.username : 'unknown'
            },
            source: 'app'
        });

        console.log(`Persisted control request id=${cmd._id} user=${req.account?.username} -> device=${deviceId} action=`, action);

        // Return 202 Accepted to indicate we've received and queued the command.
        return res.status(202).json({ status: 'accepted', deviceId, action, commandId: cmd._id });
    } catch (err) {
        console.error('controlDevice error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

module.exports.controlDeviceFromVoice = async (req, res) => {
    try {
        const configuredSecret = (process.env.VOICE_BRIDGE_SECRET || '').trim();
        if (!configuredSecret) {
            return res.status(503).json({ error: 'VOICE_BRIDGE_SECRET is not configured' });
        }

        // --- HMAC-SHA256 verification with replay protection ---
        const signature = String(req.headers['x-signature'] || '').trim();
        const timestamp = String(req.headers['x-timestamp'] || '').trim();

        if (!signature || !timestamp) {
            return res.status(401).json({ error: 'Missing X-Signature or X-Timestamp header' });
        }

        // Reject requests older than 60 seconds (replay protection)
        const nowSec = Math.floor(Date.now() / 1000);
        const reqSec = parseInt(timestamp, 10);
        if (isNaN(reqSec) || Math.abs(nowSec - reqSec) > 60) {
            return res.status(401).json({ error: 'Request expired or invalid timestamp' });
        }

        // Recompute HMAC: message = timestamp + "." + rawBody
        const rawBody = typeof req.rawBody === 'string' ? req.rawBody : JSON.stringify(req.body);
        const message = timestamp + '.' + rawBody;
        const expectedSignature = crypto
            .createHmac('sha256', configuredSecret)
            .update(message)
            .digest('hex');

        if (!crypto.timingSafeEqual(
            Buffer.from(signature, 'hex'),
            Buffer.from(expectedSignature, 'hex')
        )) {
            return res.status(401).json({ error: 'Invalid HMAC signature' });
        }

        const body = req.body || {};
        const meta = body.meta || {};
        if (meta.is_valid !== true) {
            return res.status(403).json({ error: 'Voice verification failed. Command rejected.' });
        }

        const deviceId = String(body.deviceId || '').trim();
        const command = body.command || {};
        const action = String(command.action || '').trim();
        if (!deviceId) return res.status(400).json({ error: 'deviceId is required' });
        if (!ALLOWED_ACTIONS.has(action)) {
            return res.status(400).json({ error: 'Invalid or unsupported action' });
        }

        const actionBody = {
            action,
            ...(command.seconds !== undefined ? { seconds: command.seconds } : {}),
            ...(command.sensor !== undefined ? { sensor: command.sensor } : {})
        };

        const cmd = await queueControlCommand({
            deviceId,
            body: actionBody,
            performedBy: {
                userId: null,
                username: 'voice_assistant'
            },
            source: 'system'
        });

        return res.status(202).json({
            status: 'accepted',
            source: 'voice_server',
            deviceId,
            action,
            commandId: cmd._id,
            voiceMeta: body.meta || {}
        });
    } catch (err) {
        console.error('controlDeviceFromVoice error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// Poll pending commands for a given deviceId. Devices should call this endpoint
// to fetch commands queued for them. If DEVICE_POLL_SECRET is set in env,
// the device must provide the same secret in the 'x-device-secret' header.
module.exports.pollCommands = async (req, res) => {
    try {
        const deviceId = req.params.deviceId;
        // Find pending commands for this device (FIFO)
        const cmds = await PendingCommand.find({ deviceId, status: 'pending' }).sort({ createdAt: 1 }).lean();
        if (!cmds || cmds.length === 0) return res.json({ commands: [] });

        const ids = cmds.map(c => c._id);
        // Mark them as 'sent'
        await PendingCommand.updateMany({ _id: { $in: ids } }, { $set: { status: 'sent' } });

        // Return commands to the device - ensure _id is properly converted to string
        return res.json({
            commands: cmds.map(c => ({
                commandId: c._id.toString(),
                action: c.action,
                requestedBy: c.requestedByUsername
            }))
        });
    } catch (err) {
        console.error('pollCommands error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// Device acknowledges a command execution. Body: { status: 'done'|'failed', result?: any }
module.exports.ackCommand = async (req, res) => {
    try {
        const { deviceId, commandId } = req.params;
        const body = req.body || {};
        const newStatus = body.status === 'failed' ? 'failed' : 'done';

        const cmd = await PendingCommand.findOne({ _id: commandId, deviceId });
        if (!cmd) return res.status(404).json({ error: 'Command not found' });

        cmd.status = newStatus;
        cmd.deliveredAt = new Date();
        if (body.result) cmd.result = body.result;
        await cmd.save();

        // Update ActionLog when command is acknowledged
        await ActionLog.findOneAndUpdate(
            { 'details.commandId': commandId },
            {
                $set: {
                    'result.status': newStatus === 'done' ? 'success' : 'failed',
                    'result.message': body.result?.message || (newStatus === 'done' ? 'Executed successfully' : 'Execution failed'),
                    'metadata.acknowledgedAt': new Date()
                }
            }
        );

        return res.json({ status: 'ok', commandId: cmd._id, newStatus: cmd.status });
    } catch (err) {
        console.error('ackCommand error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// Log action directly from device (e.g., keypad password change)
// Body: { actionType, details, performedBy, result }
module.exports.logDeviceAction = async (req, res) => {
    try {
        const { deviceId } = req.params;
        const body = req.body || {};

        // Validate required fields
        if (!body.actionType) {
            return res.status(400).json({ error: 'actionType is required' });
        }

        // Create ActionLog entry — auto-add description if not provided
        const actionDesc = body.details?.description
            || ACTION_DESCRIPTIONS[body.details?.action]
            || ACTION_DESCRIPTIONS[body.actionType]
            || body.actionType;

        const actionLog = new ActionLog({
            actionType: body.actionType,
            deviceId,
            performedBy: {
                userId: body.performedBy?.userId || null,
                username: body.performedBy?.username || 'local_user',
                source: body.performedBy?.source || 'keypad'
            },
            details: {
                ...body.details,
                description: actionDesc,
            },
            result: {
                status: body.result?.status || 'success',
                message: body.result?.message || 'Executed successfully',
                errorCode: body.result?.errorCode
            },
            ipAddress: req.ip || req.connection.remoteAddress,
            metadata: {
                timestamp: new Date(),
                ...body.metadata
            }
        });

        await actionLog.save();

        console.log(`Device ${deviceId} logged action: ${body.actionType} via ${body.performedBy?.source || 'keypad'}`);

        return res.status(201).json({
            status: 'ok',
            logId: actionLog._id,
            message: 'Action logged successfully'
        });
    } catch (err) {
        console.error('logDeviceAction error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
