const path = require('path');
// Load .env from project root
require('dotenv').config({ path: path.resolve(__dirname, '..', '.env') });
const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const mongoose = require('mongoose');

// ROUTES
const authRoutes = require('./routes/authroute'); // ✅ THÊM MỚI TỪ FILE 2
const accountRoutes = require('./routes/accountRoutes');
const controlRoutes = require('./routes/controlRoutes');
const deviceRoutes = require('./routes/deviceRoutes');
const permissionRoutes = require('./routes/permissionRoutes');
const actionLogRoutes = require('./routes/actionLogRoutes');
const antiSpoofLogRoutes = require('./routes/antiSpoofLogRoutes');

const Account = require('./models/Account');
const { hashPassword } = require('./utils/hash');

const app = express();
app.use(helmet());

// Hỗ trợ lấy IP thật qua Proxy/Load Balancer
app.set('trust proxy', 1);

// Capture raw body for HMAC verification
app.use(express.json({
    verify: (req, res, buf, encoding) => {
        req.rawBody = buf.toString(encoding || 'utf8');
    }
}));

// Rate limit
const limiter = rateLimit({
    windowMs: 1 * 60 * 1000,
    max: 1000,
    standardHeaders: false,
    legacyHeaders: false,
    validate: { trustProxy: false },
});
app.use(limiter);

// ================= ROUTES =================

app.use('/api/auth', authRoutes);

app.use('/api/accounts', accountRoutes);
app.use('/api', controlRoutes);
app.use('/api', deviceRoutes);
app.use('/api', permissionRoutes);
app.use('/api', actionLogRoutes);
app.use('/api', antiSpoofLogRoutes);

// health
app.get('/health', (req, res) => res.json({ ok: true }));

const PORT = process.env.PORT || 4000;

async function start() {
    const mongo = process.env.MONGODB_URI || process.env.MONGO_URI || 'mongodb://localhost:27017/iot_accounts';

    try {
        const display = (mongo || '').replace(/(:\/\/)(.*@)/, '$1****@');
        console.log('Connecting to MongoDB:', display);
    } catch (_) { }

    // Sử dụng cú pháp connect gọn hơn của file 2
    await mongoose.connect(mongo);
    console.log('✅ Connected to MongoDB');

    // Bootstrap admin
    try {
        const adminCount = await Account.countDocuments({ role: 'admin' });
        if (adminCount === 0) {
            const envAdminUser = process.env.ADMIN_USERNAME;
            const envAdminPass = process.env.ADMIN_PASSWORD;
            if (envAdminUser && envAdminPass) {
                const passwordHash = await hashPassword(envAdminPass);

                // Dùng Account.create cho hiện đại như file 2
                await Account.create({
                    username: envAdminUser,
                    passwordHash,
                    role: 'admin'
                });
                console.log('✅ Bootstrapped initial admin:', envAdminUser);
            } else {
                console.warn('⚠ No admin exists and ADMIN_USERNAME/ADMIN_PASSWORD not set.');
            }
        }
    } catch (e) {
        console.warn('Admin bootstrap warning:', e?.message || e);
    }

    app.listen(PORT, () => console.log(`🚀 Server listening on ${PORT}`));
}

start().catch(err => {
    console.error('❌ Failed to start server', err);
    process.exit(1);
});

module.exports = app;
