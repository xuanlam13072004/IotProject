const jwt = require('../utils/jwt');
const Account = require('../models/Account');

exports.loginByFace = async (req, res) => {
    try {
        const { identity } = req.body;

        if (!identity) {
            return res.status(400).json({ message: 'Missing identity' });
        }

        // ✅ CHỈ SO ROLE = IDENTITY (Face AI trả về tên/role đã train)
        const user = await Account.findOne({ role: identity });

        if (!user) {
            return res.status(401).json({
                message: 'Face recognized but role not allowed'
            });
        }

        // JWT payload phải có "id" để middleware authenticate nhận diện (giống login password)
        const token = jwt.sign({
            id: user._id.toString(),
            username: user.username,
            role: user.role,
            modules: user.modules
        });

        return res.json({
            success: true,
            identity,
            role: user.role,
            token
        });

    } catch (error) {
        console.error('loginByFace error:', error);
        return res.status(500).json({ message: 'Server error' });
    }
};