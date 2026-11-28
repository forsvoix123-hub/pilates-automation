import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { sessionCookieOptions, supabaseConfig } from "./lib/supabase/config";

export async function proxy(request: NextRequest) {
  const config = supabaseConfig();
  if (!config) return NextResponse.next();
  let response = NextResponse.next({ request });
  const db = createServerClient(config.url, config.key, {
    cookieOptions: sessionCookieOptions,
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(values, headers) {
        for (const { name, value } of values) request.cookies.set(name, value);
        response = NextResponse.next({ request });
        for (const { name, value, options } of values) response.cookies.set(name, value, options);
        for (const [name, value] of Object.entries(headers ?? {})) response.headers.set(name, value);
      },
    },
  });
  await db.auth.getClaims();
  return response;
}

export const config = { matcher: ["/", "/admin", "/login"] };
