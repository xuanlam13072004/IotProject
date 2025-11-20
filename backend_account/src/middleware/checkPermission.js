// Middleware kiểm tra quyền chi tiết cho từng action
const checkPermission = (category, action) => {
    return (req, res, next) => {
        // Admin luôn được phép
        if (req.account && req.account.role === 'admin') {
            return next();
        }

        // Kiểm tra quyền cụ thể
        if (!req.account) {
            return res.status(401).json({ error: 'Unauthorized: Not authenticated' });
        }

        const hasPermission = req.account.hasPermission(category, action);

        if (!hasPermission) {
            return res.status(403).json({
                error: 'Forbidden: Insufficient permissions',
                required: `${category}.${action}`,
                message: `Bạn không có quyền thực hiện thao tác này (${category}: ${action})`
            });
        }

        next();
    };
};

// Helper để map action → permission
const getPermissionFromAction = (action) => {
    const actionMap = {
        'open_door': { category: 'door', action: 'open' },
        'close_door': { category: 'door', action: 'close' },
        'open_awning': { category: 'awning', action: 'open' },
        'close_awning': { category: 'awning', action: 'close' },
        'set_auto': { category: 'awning', action: 'setMode' },
        'set_manual': { category: 'awning', action: 'setMode' },
        'set_snooze': { category: 'alarm', action: 'snooze' },
        'cancel_snooze': { category: 'alarm', action: 'cancelSnooze' }
    };

    return actionMap[action] || null;
};

// Middleware động kiểm tra quyền dựa trên action trong body
const checkActionPermission = (req, res, next) => {
    // Admin luôn được phép
    if (req.account && req.account.role === 'admin') {
        return next();
    }

    const action = req.body?.action;
    if (!action) {
        return res.status(400).json({ error: 'Action is required' });
    }

    const permission = getPermissionFromAction(action);
    if (!permission) {
        // Action không được định nghĩa trong permission map
        return res.status(400).json({ error: `Unknown action: ${action}` });
    }

    // Kiểm tra quyền sensor-specific cho alarm
    if (permission.category === 'alarm' && permission.action === 'snooze') {
        const sensor = req.body?.sensor || 'all';
        let specificAction = 'snooze';

        if (sensor === 'all') specificAction = 'snoozeAll';
        else if (sensor === 'fire') specificAction = 'snoozeFire';
        else if (sensor === 'gas') specificAction = 'snoozeGas';

        const hasPermission = req.account.hasPermission('alarm', specificAction);
        if (!hasPermission) {
            return res.status(403).json({
                error: 'Forbidden: Insufficient permissions',
                required: `alarm.${specificAction}`,
                message: `Bạn không có quyền tắt báo động ${sensor === 'all' ? 'tất cả' : sensor}`
            });
        }
    } else {
        // Kiểm tra quyền thông thường
        const hasPermission = req.account.hasPermission(permission.category, permission.action);
        if (!hasPermission) {
            return res.status(403).json({
                error: 'Forbidden: Insufficient permissions',
                required: `${permission.category}.${permission.action}`,
                message: `Bạn không có quyền thực hiện thao tác này`
            });
        }
    }

    next();
};

module.exports = {
    checkPermission,
    checkActionPermission
};
