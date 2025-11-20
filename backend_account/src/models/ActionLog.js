// backend_account/src/models/ActionLog.js
// Schema for logging all important actions (password changes, device control, etc.)
const mongoose = require('mongoose');

const actionLogSchema = new mongoose.Schema(
    {
        // Type of action performed
        actionType: {
            type: String,
            required: true,
            enum: [
                'change_password',
                'control_device',
                'set_snooze',
                'cancel_snooze',
                'door_open',
                'door_close',
                'alarm_trigger',
                'system_mode_change',
                'other'
            ],
            index: true,
        },

        // Which device was affected
        deviceId: {
            type: String,
            required: true,
            index: true,
        },

        // Who performed this action
        performedBy: {
            userId: {
                type: mongoose.Schema.Types.ObjectId,
                ref: 'Account',
                index: true,
            },
            username: {
                type: String,
                index: true,
            },
            source: {
                type: String,
                enum: ['app', 'keypad', 'system', 'remote', 'schedule'],
                default: 'app'
            }
        },

        // Detailed information about the action
        details: {
            type: Object,
            default: {}
        },

        // Result/outcome of the action
        result: {
            status: {
                type: String,
                enum: ['success', 'failed', 'pending'],
                default: 'pending'
            },
            message: String,
            errorCode: String,
        },

        // IP address if available
        ipAddress: String,

        // Additional metadata
        metadata: {
            type: Object,
            default: {}
        }
    },
    { timestamps: true }
);

// Compound indexes for common queries
actionLogSchema.index({ deviceId: 1, createdAt: -1 });
actionLogSchema.index({ 'performedBy.userId': 1, createdAt: -1 });
actionLogSchema.index({ actionType: 1, createdAt: -1 });
actionLogSchema.index({ deviceId: 1, actionType: 1, createdAt: -1 });

// TTL index - auto delete logs older than 180 days (6 months)
actionLogSchema.index({ createdAt: 1 }, { expireAfterSeconds: 15552000 }); // 180 days

module.exports = mongoose.model('ActionLog', actionLogSchema);
