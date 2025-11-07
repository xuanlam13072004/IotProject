// src/app.js
import express from "express";
import deviceRoutes from "./routes/deviceRoutes.js";

const app = express();
// Capture raw body (as string) so middleware can compare exact payload used by device
app.use(express.json({
    verify: (req, res, buf) => {
        try {
            req.rawBody = buf.toString();
        } catch (e) {
            req.rawBody = undefined;
        }
    }
})); // Đọc JSON body

app.use("/api", deviceRoutes); // mount routes

app.get("/", (req, res) => {
    res.send("ESP32 Backend is running...");
});

export default app;
