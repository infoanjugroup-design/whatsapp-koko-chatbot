// Password hashing for koko-chatbot accounts (user_wallets.password_hash).
// Ported 1:1 from the main koko-website app's lib/chatbot/password.ts so
// hashes stay byte-compatible between both services — same Node scrypt,
// same stored format: "scrypt:<saltHex>:<hashHex>".

import { scrypt, randomBytes, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const scryptAsync = promisify(scrypt);
const KEY_LENGTH = 64;

export async function hashPassword(plain) {
  const salt = randomBytes(16).toString("hex");
  const derived = await scryptAsync(plain, salt, KEY_LENGTH);
  return `scrypt:${salt}:${derived.toString("hex")}`;
}

export async function verifyPassword(plain, stored) {
  if (!stored) return false;
  const parts = stored.split(":");
  if (parts.length !== 3 || parts[0] !== "scrypt") return false;
  const [, salt, hashHex] = parts;
  try {
    const derived = await scryptAsync(plain, salt, KEY_LENGTH);
    const storedBuf = Buffer.from(hashHex, "hex");
    if (derived.length !== storedBuf.length) return false;
    return timingSafeEqual(derived, storedBuf);
  } catch {
    return false;
  }
}
