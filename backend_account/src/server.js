const path = require('path');
// Load .env from project root (parent of src). This makes running
// `node src/server.js` work regardless of current working directory.
require('dotenv').config({ path: path.resolve(__dirname, '..', '.env') });
const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const mongoose = require('mongoose');
const accountRoutes = require('./routes/accountRoutes');
const controlRoutes = require('./routes/controlRoutes');
const deviceRoutes = require('./routes/deviceRoutes');
const permissionRoutes = require('./routes/permissionRoutes');
const actionLogRoutes = require('./routes/actionLogRoutes');
const Account = require('./models/Account');
const { hashPassword } = require('./utils/hash');

const app = express();
app.use(helmet());
// Capture raw body for HMAC verification by devices (middleware will read req.rawBody)
app.use(express.json({ verify: (req, res, buf, encoding) => { req.rawBody = buf.toString(encoding || 'utf8'); } }));

// Increased rate limit for local development (ESP32 polls every 3s + app usage)
// standardHeaders and legacyHeaders disabled to avoid X-Forwarded-For warnings
const limiter = rateLimit({
    windowMs: 1 * 60 * 1000,
    max: 1000,
    standardHeaders: false,
    legacyHeaders: false
});
app.use(limiter);

// routes
app.use('/api/accounts', accountRoutes);
// control routes (protected endpoints for controlling devices)
app.use('/api', controlRoutes);
// device registration (admin)
app.use('/api', deviceRoutes);
// permission management routes
app.use('/api', permissionRoutes);
// action log routes (history)
app.use('/api', actionLogRoutes);

// health
app.get('/health', (req, res) => res.json({ ok: true }));

const PORT = process.env.PORT || 4000;

async function start() {
    // Accept either MONGODB_URI or MONGO_URI (some services use a different env name)
    const mongo = process.env.MONGODB_URI || process.env.MONGO_URI || 'mongodb://localhost:27017/iot_accounts';
    try {
        const display = (mongo || '').replace(/(:\/\/)(.*@)/, '$1****@');
        console.log('Connecting to MongoDB using URI:', display);
    } catch (_) { }
    await mongoose.connect(mongo, { useNewUrlParser: true, useUnifiedTopology: true });
    console.log('Connected to MongoDB');

    // Bootstrap admin ONLY if none exists, using environment variables.
    // This avoids embedding credentials in code. Provide ADMIN_USERNAME and ADMIN_PASSWORD in .env for first-run bootstrap.
    try {
        const adminCount = await Account.countDocuments({ role: 'admin' });
        if (adminCount === 0) {
            const envAdminUser = process.env.ADMIN_USERNAME;
            const envAdminPass = process.env.ADMIN_PASSWORD;
            if (envAdminUser && envAdminPass) {
                const passwordHash = await hashPassword(envAdminPass);
                const admin = new Account({ username: envAdminUser, passwordHash, role: 'admin' });
                await admin.save();
                console.log('Bootstrapped initial admin from env:', envAdminUser);
            } else {
                console.warn('No admin exists and ADMIN_USERNAME/ADMIN_PASSWORD not set. Please seed an admin user.');
            }
        }
    } catch (e) {
        console.warn('Warning while checking/bootstrapping admin', e?.message || e);
    }
    app.listen(PORT, () => console.log(`Server listening on ${PORT}`));
}

start().catch(err => {
    console.error('Failed to start server', err);
    process.exit(1);
});

module.exports = app;
