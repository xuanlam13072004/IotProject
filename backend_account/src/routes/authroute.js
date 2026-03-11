const express = require('express');
const router = express.Router();

const authController = require('../controllers/authcontroller');

router.post('/login-face', authController.loginByFace);

module.exports = router;