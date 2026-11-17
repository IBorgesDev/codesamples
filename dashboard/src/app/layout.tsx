import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Live Ops Dashboard",
  description: "Live players, trades and global events across every server",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className="h-full antialiased">
      <body className="min-h-full">{children}</body>
    </html>
  );
}
