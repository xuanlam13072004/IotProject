// server.js
import dotenv from "dotenv";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
import connectDB from "./config/db.js";
import app from "./app.js";

// Xác định __dirname và load .env ở thư mục gốc (một cấp trên `src`)
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
// projectRoot = one level above src
const projectRoot = resolve(__dirname, "..");
dotenv.config({ path: resolve(projectRoot, ".env") });

// Kiểm tra biến môi trường
if (!process.env.MONGO_URI) {
    console.error(
        "❌ MONGO_URI is not set. Make sure .env exists in the project root."
    );
    process.exit(1);
}

// Kết nối MongoDB
await connectDB();

// Cấu hình cổng chạy server
const PORT = process.env.PORT || 5000;

// Khởi động server Express (bind explicitly to 0.0.0.0 so LAN devices can connect)
const HOST = process.env.HOST || '0.0.0.0';
app.listen(PORT, HOST, () => {
    console.log(`🚀 ESP32 backend server running on ${HOST}:${PORT}`);
    console.log(`🗄️  MongoDB connected: ${process.env.MONGO_URI}`);
});
