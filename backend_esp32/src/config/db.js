
import mongoose from "mongoose";

const connectDB = async () => {
    const mongoUri = process.env.MONGO_URI;
    if (!mongoUri) {
        console.error("❌ MongoDB connection error: MONGO_URI is not defined in environment variables.");
        return;
    }

    try {
        // Mongoose v6+ doesn't require those options; pass only the URI
        const conn = await mongoose.connect(mongoUri);
        console.log(`✅ MongoDB connected: ${conn.connection.host}`);
    } catch (error) {
        console.error("❌ MongoDB connection error:", error.message);
        process.exit(1); // Exit the process on connection error
    }
};

export default connectDB;
