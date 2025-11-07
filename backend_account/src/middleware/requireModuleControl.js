/**
 * Middleware factory to require that the authenticated account has canControl permission
 * for a module identified in req.params[paramName]. Admins bypass this check.
 *
 * @param {string} paramName - the name of the route param that contains the module/device id
 */
module.exports = function requireModuleControl(paramName = 'deviceId') {
    return (req, res, next) => {
        try {
            if (!req.account) return res.status(401).json({ error: 'Not authenticated' });
            if (req.account.role === 'admin') return next();

            const moduleId = req.params && req.params[paramName];
            if (!moduleId) return res.status(400).json({ error: 'Missing module id parameter' });

            const modules = req.account.modules || [];
            const entry = modules.find(m => String(m.moduleId) === String(moduleId));
            if (!entry || !entry.canControl) return res.status(403).json({ error: 'No control permission for module' });

            next();
        } catch (err) {
            console.error('requireModuleControl error', err);
            res.status(500).json({ error: 'Server error' });
        }
    };
};
