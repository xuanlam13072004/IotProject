const express = require('express');
const router = express.Router();
const controller = require('../controllers/accountController');
const { authenticate } = require('../middleware/auth');
const adminOnly = require('../middleware/adminOnly');

// public: login
router.post('/login', controller.login);

// admin-only account management
router.post('/', authenticate, adminOnly, controller.createAccount);
router.get('/', authenticate, adminOnly, controller.listAccounts);
router.get('/:id', authenticate, controller.getAccount);
router.patch('/:id', authenticate, adminOnly, controller.updateAccount);
router.delete('/:id', authenticate, adminOnly, controller.deleteAccount);

module.exports = router;
