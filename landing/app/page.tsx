import Nav from "@/components/Nav";
import Hero from "@/components/Hero";
import HowItWorks from "@/components/HowItWorks";
import PrivacyBand from "@/components/PrivacyBand";
import AppGrid from "@/components/AppGrid";
import ModeShowcase from "@/components/ModeShowcase";
import DownloadFooter from "@/components/DownloadFooter";

export default function Home() {
  return (
    <main className="min-h-[100dvh]">
      <Nav />
      <Hero />
      <HowItWorks />
      <PrivacyBand />
      <AppGrid />
      <ModeShowcase />
      <DownloadFooter />
    </main>
  );
}
