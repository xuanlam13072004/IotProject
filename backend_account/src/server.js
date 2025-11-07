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
const Account = require('./models/Account');
const { hashPassword } = require('./utils/hash');

const app = express();
app.use(helmet());
// Capture raw body for HMAC verification by devices (middleware will read req.rawBody)
app.use(express.json({ verify: (req, res, buf, encoding) => { req.rawBody = buf.toString(encoding || 'utf8'); } }));

const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 200 });
app.use(limiter);

// routes
app.use('/api/accounts', accountRoutes);
// control routes (protected endpoints for controlling devices)
app.use('/api', controlRoutes);
// device registration (admin)
app.use('/api', deviceRoutes);

// health
app.get('/health', (req, res) => res.json({ ok: true }));

const PORT = process.env.PORT || 4000;

async function start() {
    // Accept either MONGODB_URI or MONGO_URI (some services use a different env name)
    const mongo = process.env.MONGODB_URI || process.env.MONGO_URI || 'mongodb://localhost:27017/iot_accounts';
    try {
        // Mask credentials when printing
        const display = (mongo || '').replace(/(:\/\/)(.*@)/, '$1****@');
        console.log('Connecting to MongoDB using URI:', display);
    } catch (_) { }
    await mongoose.connect(mongo, { useNewUrlParser: true, useUnifiedTopology: true });
    console.log('Connected to MongoDB');

    // Optionally bootstrap an initial admin when environment variables are provided.
    const adminUser = process.env.ADMIN_USERNAME;
    const adminPass = process.env.ADMIN_PASSWORD;
    if (adminUser && adminPass) {
        const existingAdmin = await Account.findOne({ role: 'admin' });
        if (!existingAdmin) {
            const passwordHash = await hashPassword(adminPass);
            const admin = new Account({ username: adminUser, passwordHash, role: 'admin' });
            await admin.save();
            console.log('Created initial admin user:', adminUser);
        }
    }
    app.listen(PORT, () => console.log(`Server listening on ${PORT}`));
}

start().catch(err => {
    console.error('Failed to start server', err);
    process.exit(1);
});

module.exports = app;
