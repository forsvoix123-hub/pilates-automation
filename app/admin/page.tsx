import { Admin } from "@/components/admin";
import { StudioDataProvider } from "@/components/studio-data";
import { studioAdmin, studioSession } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import Link from "next/link";

export default async function Page() {
  const session = await studioSession();
  if (!session.db) return <main className="frame content"><p role="alert">{session.error}</p><Link className="contact-link" href="/login?next=admin">Войти</Link></main>;
  if (!session.userId) redirect("/login?next=admin");
  const { allowed, error } = await studioAdmin(session.db);
  if (!allowed) return (
    <main className="frame content">
      <p role="alert">{error ?? "Вход в CRM доступен только администраторам."}</p>
      <Link className="contact-link" href="/">Перейти в клиентское приложение</Link>
    </main>
  );
  return <StudioDataProvider admin><Admin /></StudioDataProvider>;
}
