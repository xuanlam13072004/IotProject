Expected responses for the smoke test sequence

Preconditions:
- Server running at http://localhost:4000
- MongoDB reachable and the server either bootstrapped an admin via ADMIN_USERNAME/ADMIN_PASSWORD or an admin account already exists with the credentials in the test.

Sequence & expected results:

1) POST /api/accounts/login (admin)
   - Status: 200
   - Body: { token: "<jwt>", expiresIn: "1h" }

2) POST /api/accounts (create testuser) with admin token
   - Status: 201 (created)
   - Body: created account object without passwordHash

3) POST /api/accounts/login (testuser)
   - Status: 200
   - Body: { token: "<jwt>", expiresIn: "1h" }

4) POST /api/devices/:deviceId/control with testuser token (no permission)
   - Status: 403
   - Body: { error: 'No control permission for module' }

5) PATCH /api/accounts/:id to grant modules (admin)
   - Status: 200
   - Body: updated account object (modules should include the deviceId with canControl: true)

6) POST /api/devices/:deviceId/control with testuser token (after grant)
   - Status: 202
   - Body: { status: 'accepted', deviceId: '<deviceId>', action: { ... } }

If any step returns different codes, check server logs and ensure environment variables and MongoDB are correct.
