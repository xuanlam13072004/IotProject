function adminOnly(req, res, next) {
    if (!req.account) return res.status(401).json({ error: 'Not authenticated' });
    if (req.account.role !== 'admin') return res.status(403).json({ error: 'Admin role required' });
    next();
}

module.exports = adminOnly;
