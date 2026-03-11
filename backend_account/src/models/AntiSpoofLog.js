const mongoose = require('mongoose');

const antiSpoofLogSchema = new mongoose.Schema(
    {
        ownerId: {
            type: String,
            required: true,
            index: true,
        },
        action: {
            type: String,
            required: true,
            enum: ['train', 'retrain', 'enroll'],
            index: true,
        },
        numBonafide: {
            type: Number,
            default: 0,
        },
        numSpoofSimulated: {
            type: Number,
            default: 0,
        },
        numSpoofReal: {
            type: Number,
            default: 0,
        },
        numSpoofRealNew: {
            type: Number,
            default: 0,
        },
        savedSpoofFiles: {
            type: [String],
            default: [],
        },
        epochs: {
            type: Number,
            default: 0,
        },
        finalLoss: {
            type: Number,
            default: null,
        },
        source: {
            type: String,
            enum: ['app', 'api', 'system'],
            default: 'api',
        },
        metadata: {
            type: Object,
            default: {},
        },
    },
    { timestamps: true }
);

antiSpoofLogSchema.index({ ownerId: 1, createdAt: -1 });
antiSpoofLogSchema.index({ action: 1, createdAt: -1 });

module.exports = mongoose.model('AntiSpoofLog', antiSpoofLogSchema);
