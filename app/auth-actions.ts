"use server";

import { redirect } from "next/navigation";
import { serverClient } from "@/lib/supabase/server";

export async function login(_previous: string, form: FormData) {
  const email = String(form.get("email") ?? "").trim();
  const password = String(form.get("password") ?? "");
  if (!email || !password) return "Введите email и пароль.";
  const db = await serverClient();
  if (!db) return "Проверьте настройки Supabase в .env.local.";
  const { error } = await db.auth.signInWithPassword({ email, password });
  if (error) {
    if (error.code === "invalid_credentials") return "Неверный email или пароль.";
    if (error.code === "email_not_confirmed") return "Подтвердите email в Supabase Auth.";
    return "Войти не удалось. Повторите попытку позже.";
  }
  redirect(form.get("destination") === "admin" ? "/admin" : "/");
}

export async function logout() {
  const db = await serverClient();
  if (db) {
    const { error } = await db.auth.signOut({ scope: "local" });
    if (error) redirect("/login?logout=failed");
  }
  redirect("/login");
}
