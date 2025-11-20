// Controller để quản lý permissions của user
const Account = require('../models/Account');

// GET /api/admin/users/:userId/permissions - Lấy quyền của user
module.exports.getUserPermissions = async (req, res) => {
    try {
        const { userId } = req.params;
        const account = await Account.findById(userId);

        if (!account) {
            return res.status(404).json({ error: 'User not found' });
        }

        return res.json({
            userId: account._id,
            username: account.username,
            role: account.role,
            permissions: account.permissions || {}
        });
    } catch (err) {
        console.error('getUserPermissions error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// PUT /api/admin/users/:userId/permissions - Cập nhật quyền của user
module.exports.updateUserPermissions = async (req, res) => {
    try {
        const { userId } = req.params;
        const { permissions } = req.body;

        if (!permissions) {
            return res.status(400).json({ error: 'permissions is required' });
        }

        const account = await Account.findById(userId);
        if (!account) {
            return res.status(404).json({ error: 'User not found' });
        }

        // Không cho phép sửa permissions của admin
        if (account.role === 'admin') {
            return res.status(403).json({ error: 'Cannot modify admin permissions' });
        }

        account.permissions = permissions;
        await account.save();

        console.log(`Admin ${req.account.username} updated permissions for ${account.username}`);

        return res.json({
            message: 'Permissions updated successfully',
            userId: account._id,
            username: account.username,
            permissions: account.permissions
        });
    } catch (err) {
        console.error('updateUserPermissions error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};

// GET /api/accounts/me/permissions - User lấy quyền của chính mình
module.exports.getMyPermissions = async (req, res) => {
    try {
        const account = req.account; // Từ authenticate middleware

        return res.json({
            userId: account._id,
            username: account.username,
            role: account.role,
            permissions: account.permissions || {}
        });
    } catch (err) {
        console.error('getMyPermissions error', err);
        return res.status(500).json({ error: 'Server error' });
    }
};
