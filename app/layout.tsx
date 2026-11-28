import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "HARMONY FAMILY",
  description: "Студия пилатеса и косметологии",
};

export default function Layout({ children }: { children: React.ReactNode }) {
  return <html lang="ru"><body>{children}</body></html>;
}
