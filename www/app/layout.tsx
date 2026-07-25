import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://portal-terminal.dev"),
  title: "Portal — Give your Mac a portal",
  description:
    "A terminal app for Mac and iPhone that finds your Macs automatically. Open or rejoin shells with no SSH setup.",
  icons: {
    icon: "/portal-icon.png",
    apple: "/portal-icon.png",
  },
  openGraph: {
    title: "Portal — Give your Mac a portal",
    description:
      "A terminal app for Mac and iPhone that finds your Macs automatically. No SSH setup or configuration.",
    images: [{ url: "/og.png", width: 1730, height: 909, alt: "Portal" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Portal — Give your Mac a portal",
    description:
      "A terminal app for Mac and iPhone that finds your Macs automatically. No SSH setup or configuration.",
    images: ["/og.png"],
  },
};

export const viewport: Viewport = {
  themeColor: "#020307",
  colorScheme: "dark",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>
        {children}
      </body>
    </html>
  );
}
