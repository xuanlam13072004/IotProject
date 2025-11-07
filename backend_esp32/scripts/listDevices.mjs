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

const run = async () => {
  try {
    await connectDB();
    const devices = await Device.find({}, { deviceId: 1, secretKey: 1, _id: 0 }).lean();
    console.log('Devices in DB:');
    console.log(JSON.stringify(devices, null, 2));
    process.exit(0);
  } catch (err) {
    console.error('Error listing devices:', err);
    process.exit(2);
  }
};

run();
