export function supabaseConfig() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const key = (process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)?.trim();
  if (!url || !key) return null;
  try {
    if (new URL(url).protocol !== "https:") return null;
    if (key.startsWith("sb_publishable_")) return { url, key };
    const payload = JSON.parse(Buffer.from(key.split(".")[1], "base64url").toString("utf8"));
    return payload.role === "anon" ? { url, key } : null;
  } catch {
    return null;
  }
}
import "server-only";

export const sessionCookieOptions = { httpOnly: true, secure: process.env.NODE_ENV === "production" };
