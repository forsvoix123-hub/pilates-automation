import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { sessionCookieOptions, supabaseConfig } from "./config";

export async function serverClient(writeCookies = true) {
  const jar = await cookies();
  const config = supabaseConfig();
  if (!config) return null;
  return createServerClient(config.url, config.key, {
    cookieOptions: sessionCookieOptions,
    cookies: {
      getAll: () => jar.getAll(),
      setAll(values) {
        if (writeCookies) for (const { name, value, options } of values) jar.set(name, value, options);
      },
    },
  });
}

export async function studioSession() {
  const db = await serverClient(false);
  if (!db) return { error: "Настройте URL и публичный ключ Supabase в .env.local." } as const;
  const { data, error } = await db.auth.getClaims();
  if (error && error.name !== "AuthSessionMissingError") {
    return { error: "Не удалось проверить сессию. Войдите снова или повторите попытку позже." } as const;
  }
  return { db, userId: data?.claims.sub };
}

export async function studioAdmin(db: NonNullable<Awaited<ReturnType<typeof serverClient>>>) {
  const { data, error } = await db.rpc("is_studio_admin");
  if (!error && typeof data === "boolean") return { allowed: data };
  switch (error?.code) {
    case "PGRST202":
      return { allowed: false, error: "Функция проверки роли CRM недоступна через API. Проверьте миграцию доступа и обновите кеш схемы PostgREST (PGRST202)." };
    case "42501":
      return { allowed: false, error: "База отклонила вызов проверки роли CRM. Проверьте SQL-права роли authenticated (42501)." };
    case "PGRST301":
    case "PGRST302":
    case "PGRST303":
      return { allowed: false, error: "Supabase не принял сессию. Войдите снова." };
    default:
      return { allowed: false, error: "Не удалось проверить права CRM. Повторите попытку." };
  }
}
