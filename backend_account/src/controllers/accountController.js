const Account = require('../models/Account');
const { hashPassword, comparePassword } = require('../utils/hash');
const jwt = require('../utils/jwt');

// POST /api/accounts/login
async function login(req, res) {
    const { username, password } = req.body || {};
    if (!username || !password) return res.status(400).json({ error: 'username and password required' });
    const account = await Account.findOne({ username });
    if (!account) return res.status(401).json({ error: 'Invalid credentials' });
    const ok = await comparePassword(password, account.passwordHash);
    if (!ok) return res.status(401).json({ error: 'Invalid credentials' });
    const token = jwt.sign({ id: account._id.toString(), username: account.username, role: account.role, modules: account.modules });
    res.json({ token, expiresIn: process.env.JWT_EXPIRES_IN || '1h' });
}

// POST /api/accounts/    (admin only)
async function createAccount(req, res) {
    const { username, password, role = 'user', modules = [] } = req.body || {};
    if (!username || !password) return res.status(400).json({ error: 'username and password required' });
    if (!['admin', 'user', 'guest'].includes(role)) return res.status(400).json({ error: 'invalid role' });
    const exists = await Account.findOne({ username });
    if (exists) return res.status(409).json({ error: 'username already exists' });
    const passwordHash = await hashPassword(password);
    const acc = new Account({ username, passwordHash, role, modules });
    await acc.save();
    const out = acc.toObject();
    delete out.passwordHash;
    res.status(201).json(out);
}

// GET /api/accounts/   (admin only)
async function listAccounts(req, res) {
    const accounts = await Account.find().select('-passwordHash').lean();
    res.json(accounts);
}

// GET /api/accounts/:id
async function getAccount(req, res) {
    const { id } = req.params;
    const acc = await Account.findById(id).select('-passwordHash').lean();
    if (!acc) return res.status(404).json({ error: 'not found' });
    res.json(acc);
}

// PATCH /api/accounts/:id   (admin only)
async function updateAccount(req, res) {
    const { id } = req.params;
    const { password, role, modules } = req.body || {};
    const target = await Account.findById(id);
    if (!target) return res.status(404).json({ error: 'not found' });
    if (role) {
        if (!['admin', 'user', 'guest'].includes(role)) return res.status(400).json({ error: 'invalid role' });
        target.role = role;
    }
    if (typeof modules !== 'undefined') {
        target.modules = modules;
    }
    if (password) {
        target.passwordHash = await hashPassword(password);
    }
    await target.save();
    const out = target.toObject();
    delete out.passwordHash;
    res.json(out);
}

// DELETE /api/accounts/:id   (admin only)
async function deleteAccount(req, res) {
    const { id } = req.params;
    const target = await Account.findById(id);
    if (!target) return res.status(404).json({ error: 'not found' });
    if (target.role === 'admin') {
        const adminCount = await Account.countDocuments({ role: 'admin' });
        if (adminCount <= 1) return res.status(400).json({ error: 'Cannot delete last admin' });
    }
    await target.deleteOne();
    res.status(204).end();
}

module.exports = { login, createAccount, listAccounts, getAccount, updateAccount, deleteAccount };
