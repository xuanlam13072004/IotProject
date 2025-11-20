// Controller to handle device control requests from authenticated users
const PendingCommand = require('../models/PendingCommand');
const Device = require('../models/Device');
const ActionLog = require('../models/ActionLog');

module.exports.controlDevice = async (req, res) => {
    try {
        const deviceId = req.params.deviceId;
        const body = req.body || {};
        const action = body.action;
        if (!action) return res.status(400).json({ error: 'action is required in body' });

        // Handle set_snooze action - update device mute state in DB
        if (action === 'set_snooze') {
            const seconds = parseInt(body.seconds) || 300; // Default 5 minutes
            const sensor = body.sensor || 'all'; // 'all', 'fire', or 'gas'
            const muteEndsAt = new Date(Date.now() + seconds * 1000);

            // Build mutedSensors array based on sensor parameter
            let mutedSensors = [];
            if (sensor === 'all') {
                mutedSensors = ['all'];
            } else if (sensor === 'fire' || sensor === 'gas') {
                // Get current mutedSensors and add new one (avoiding duplicates)
                const device = await Device.findOne({ deviceId });
                const current = device?.mutedSensors || [];
                mutedSensors = [...new Set([...current.filter(s => s !== 'all'), sensor])];
            }

            await Device.findOneAndUpdate(
                { deviceId },
                { mutedSensors, muteEndsAt },
                { new: true }
            );

            console.log(`Device ${deviceId} muted sensors [${mutedSensors}] until ${muteEndsAt} by ${req.account?.username}`);
        }

        // Handle cancel_snooze action - clear device mute state in DB
        if (action === 'cancel_snooze') {
            const sensor = body.sensor || 'all'; // Which sensor to reactivate

            let mutedSensors = [];
            if (sensor === 'all') {
                mutedSensors = []; // Clear all
            } else {
                // Remove specific sensor from array
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

            console.log(`Device ${deviceId} alarm reactivated for [${sensor}] by ${req.account?.username}`);
        }

        // Prepare action object for ESP32 (include parameters if present)
        const actionObject = {
            name: action,
            ...(body.seconds && { seconds: parseInt(body.seconds) }),
            ...(body.sensor && { sensor: body.sensor })
        };

        // Persist the command so an ESP32 or worker can pick it up reliably.
        const cmd = new PendingCommand({
            deviceId,
            action: actionObject,
            requestedBy: req.account && req.account.id ? req.account.id : undefined,
            requestedByUsername: req.account && req.account.username ? req.account.username : undefined,
            status: 'pending'
        });
        await cmd.save();

        console.log(`Persisted control request id=${cmd._id} user=${req.account?.username} -> device=${deviceId} action=`, action);

        // Log action to ActionLog for history tracking
        const actionLog = new ActionLog({
            actionType: action === 'set_snooze' ? 'set_snooze'
                : action === 'cancel_snooze' ? 'cancel_snooze'
                    : action === 'change_password' ? 'change_password'
                        : 'control_device',
            deviceId,
            performedBy: {
                userId: req.account?.id,
                username: req.account?.username || 'unknown',
                source: 'app'
            },
            details: {
                action,
                parameters: body,
                commandId: cmd._id.toString()
            },
            result: {
                status: 'pending',
                message: 'Command queued for device'
            },
            ipAddress: req.ip || req.connection.remoteAddress,
            metadata: {
                userAgent: req.headers['user-agent'],
                timestamp: new Date()
            }
        });
        await actionLog.save();

        // Return 202 Accepted to indicate we've received and queued the command.
        return res.status(202).json({ status: 'accepted', deviceId, action, commandId: cmd._id });
    } catch (err) {
        console.error('controlDevice error', err);
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
                    'result.message': body.result?.message || (newStatus === 'done' ? 'Command executed successfully' : 'Command execution failed'),
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

        // Create ActionLog entry
        const actionLog = new ActionLog({
            actionType: body.actionType,
            deviceId,
            performedBy: {
                userId: body.performedBy?.userId || null,
                username: body.performedBy?.username || 'local_user',
                source: body.performedBy?.source || 'keypad'
            },
            details: body.details || {},
            result: {
                status: body.result?.status || 'success',
                message: body.result?.message || 'Action completed',
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
