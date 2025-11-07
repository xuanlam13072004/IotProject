// Controller to handle device control requests from authenticated users
const PendingCommand = require('../models/PendingCommand');

module.exports.controlDevice = async (req, res) => {
    try {
        const deviceId = req.params.deviceId;
        const body = req.body || {};
        const action = body.action;
        if (!action) return res.status(400).json({ error: 'action is required in body' });

        // Persist the command so an ESP32 or worker can pick it up reliably.
        const cmd = new PendingCommand({
            deviceId,
            action,
            requestedBy: req.account && req.account.id ? req.account.id : undefined,
            requestedByUsername: req.account && req.account.username ? req.account.username : undefined,
            status: 'pending'
        });
        await cmd.save();

        console.log(`Persisted control request id=${cmd._id} user=${req.account?.username} -> device=${deviceId} action=`, action);

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

        // Return commands to the device
        return res.json({ commands: cmds.map(c => ({ commandId: c._id, action: c.action, requestedBy: c.requestedByUsername })) });
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

        return res.json({ status: 'ok', commandId: cmd._id, newStatus: cmd.status });
    } catch (err) {
        console.error('ackCommand error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
