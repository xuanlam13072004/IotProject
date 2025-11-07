const jwtUtil = require('../utils/jwt');
const Account = require('../models/Account');

async function authenticate(req, res, next) {
    const header = req.get('Authorization') || '';
    const matches = header.match(/^Bearer (.+)$/);
    if (!matches) return res.status(401).json({ error: 'Missing or invalid Authorization header' });

    const token = matches[1];
    try {
        const payload = jwtUtil.verify(token);
        // payload should include id
        if (!payload || !payload.id) return res.status(401).json({ error: 'Invalid token payload' });
        const account = await Account.findById(payload.id).lean();
        if (!account) return res.status(401).json({ error: 'Account not found' });
        // attach minimal info
        req.account = { id: account._id.toString(), username: account.username, role: account.role, modules: account.modules };
        next();
    } catch (err) {
        return res.status(401).json({ error: 'Invalid or expired token' });
    }
}

module.exports = { authenticate };
