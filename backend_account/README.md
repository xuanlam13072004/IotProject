# backend_account

Admin-managed account backend for the IoT smart-home project.

Features
- Single-admin model (admin creates and manages other accounts)
- Roles: admin, user, guest
- JWT authentication
- MongoDB (Mongoose) storage
- Module-level permissions per account

Quick start

1. Copy `.env.example` to `.env` and fill values:

```
MONGODB_URI=mongodb://localhost:27017/iot_accounts
JWT_SECRET=your_jwt_secret_here
JWT_EXPIRES_IN=1h
PORT=4000
ADMIN_USERNAME=admin
ADMIN_PASSWORD=your-admin-password
```

2. Install dependencies

```powershell
npm install
```

3. Start server

```powershell
npm run dev
```

Notes
- There is no public registration endpoint. Admin must create accounts via the API.
- To bootstrap an initial admin, set `ADMIN_USERNAME` and `ADMIN_PASSWORD` before first start; the server will create the admin if no admin exists.
- Use the `Authorization: Bearer <token>` header for authenticated requests.

API endpoints (summary)
- POST /api/accounts/login  { username, password } -> { token }
- POST /api/accounts       (admin) create user
- GET /api/accounts        (admin) list accounts
- GET /api/accounts/:id    (auth) get account info
- PATCH /api/accounts/:id  (admin) update role/modules/password
- DELETE /api/accounts/:id (admin) delete account (protects last admin)
