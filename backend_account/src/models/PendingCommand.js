const mongoose = require('mongoose');

const PendingCommandSchema = new mongoose.Schema({
    deviceId: { type: String, required: true },
    action: { type: Object, required: true },
    requestedBy: { type: mongoose.Schema.Types.ObjectId, ref: 'Account', required: false },
    requestedByUsername: { type: String },
    status: { type: String, enum: ['pending', 'sent', 'failed', 'done'], default: 'pending' },
    createdAt: { type: Date, default: Date.now },
    deliveredAt: { type: Date },
    result: { type: Object }
}, { timestamps: true });

module.exports = mongoose.model('PendingCommand', PendingCommandSchema);
