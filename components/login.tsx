"use client";

import { useActionState } from "react";
import { login, logout } from "@/app/auth-actions";

export function Login({ admin, failedLogout }: { admin: boolean; failedLogout: boolean }) {
  const [error, action, pending] = useActionState(login, "");
  return (
    <main className="frame content">
      <section className="card max-w-md">
        <h1 className="mb-5 text-4xl">{admin ? "Вход в CRM" : "Вход в личный кабинет"}</h1>
        {failedLogout && <form action={logout}><p role="alert">Не удалось завершить сессию.</p><button className="button my-3">Повторить выход</button></form>}
        <form action={action} className="grid gap-4">
          <input type="hidden" name="destination" value={admin ? "admin" : "studio"} />
          <label className="grid gap-1">Email<input name="email" type="email" autoComplete="username" required /></label>
          <label className="grid gap-1">Пароль<input name="password" type="password" autoComplete="current-password" required /></label>
          <button className="button" disabled={pending}>{pending ? "Входим…" : "Войти"}</button>
          {error && <p role="alert">{error}</p>}
        </form>
      </section>
    </main>
  );
}
