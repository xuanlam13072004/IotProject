import dotenv from 'dotenv';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

// point dotenv at project root (one level up from src)
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = resolve(__dirname, '..');
dotenv.config({ path: resolve(projectRoot, '.env') });

import connectDB from '../src/config/db.js';
import Device from '../src/models/Device.js';

const argv = process.argv.slice(2);
const deviceId = argv[0] || 'esp32_1';
const secretKey = argv[1] || 'my_secret_key_123';

const run = async () => {
  try {
    await connectDB();
    const existing = await Device.findOne({ deviceId });
    if (existing) {
      console.log(`Device ${deviceId} already exists. Updating secretKey.`);
      existing.secretKey = secretKey;
      await existing.save();
      console.log('Updated device:', { deviceId: existing.deviceId, secretKey: existing.secretKey });
    } else {
      const doc = await Device.create({ deviceId, secretKey });
      console.log('Created device:', { deviceId: doc.deviceId, secretKey: doc.secretKey });
    }
    process.exit(0);
  } catch (err) {
    console.error('Error adding device:', err);
    process.exit(2);
  }
};

run();
