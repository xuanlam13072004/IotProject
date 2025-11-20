const express = require('express');
const router = express.Router();
const { getUserPermissions, updateUserPermissions, getMyPermissions } = require('../controllers/permissionController');
const { authenticate } = require('../middleware/auth');
const adminOnly = require('../middleware/adminOnly');

// User routes - lấy quyền của chính mình
router.get('/accounts/me/permissions', authenticate, getMyPermissions);

// Admin routes - quản lý quyền của users
router.get('/admin/users/:userId/permissions', authenticate, adminOnly, getUserPermissions);
router.put('/admin/users/:userId/permissions', authenticate, adminOnly, updateUserPermissions);

module.exports = router;
