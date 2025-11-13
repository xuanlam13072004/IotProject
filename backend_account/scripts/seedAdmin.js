#!/usr/bin/env node
/*
 Seed an admin account without embedding credentials in server code.

 Usage:
   node scripts/seedAdmin.js --username <name> --password <pass>
 or set env ADMIN_USERNAME / ADMIN_PASSWORD and run:
   node scripts/seedAdmin.js
*/
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '..', '.env') });
const mongoose = require('mongoose');
const Account = require('../src/models/Account');
const { hashPassword } = require('../src/utils/hash');

function getArg(flag) {
    const i = process.argv.indexOf(flag);
    if (i >= 0 && i + 1 < process.argv.length) return process.argv[i + 1];
    return undefined;
}

async function main() {
    const mongo = process.env.MONGODB_URI || process.env.MONGO_URI || 'mongodb://localhost:27017/iot_accounts';
    await mongoose.connect(mongo, { useNewUrlParser: true, useUnifiedTopology: true });

    const username = getArg('--username') || process.env.ADMIN_USERNAME;
    const password = getArg('--password') || process.env.ADMIN_PASSWORD;

    if (!username || !password) {
        console.error('Missing credentials. Provide --username and --password or set ADMIN_USERNAME/ADMIN_PASSWORD in .env');
        process.exit(2);
    }

    const adminCount = await Account.countDocuments({ role: 'admin' });
    if (adminCount > 0) {
        console.log('Admin already exists. No changes were made.');
        await mongoose.disconnect();
        return;
    }

    const passwordHash = await hashPassword(password);
    const admin = new Account({ username, passwordHash, role: 'admin' });
    await admin.save();
    console.log(`Seeded admin '${username}'.`);
    await mongoose.disconnect();
}

main().catch(async (e) => {
    console.error('Failed to seed admin:', e);
    try { await mongoose.disconnect(); } catch { }
    process.exit(1);
});
