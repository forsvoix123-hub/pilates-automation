import { Login } from "@/components/login";

export default async function Page({ searchParams }: { searchParams: Promise<{ next?: string; logout?: string }> }) {
  const query = await searchParams;
  return <Login admin={query.next === "admin"} failedLogout={query.logout === "failed"} />;
}
