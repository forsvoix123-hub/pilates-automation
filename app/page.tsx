import { Studio } from "@/components/studio";
import { StudioDataProvider } from "@/components/studio-data";
import { studioSession } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export default async function Page() {
  const session = await studioSession();
  if (session.error) return <main className="frame content"><p role="alert">{session.error}</p><a className="contact-link" href="/login">Войти</a></main>;
  if (!session.userId) redirect("/login");
  return <StudioDataProvider><Studio /></StudioDataProvider>;
}
