import Image from "next/image";

export default function DownloadFooter() {
  return (
    <>
      <section id="download" className="mx-auto max-w-3xl px-6 py-20 text-center">
        <h2 className="font-display text-[36px] font-medium italic text-ink-0">Bring Owlet home</h2>
        <p className="mx-auto mt-3 max-w-[44ch] text-sm leading-relaxed text-ink-1">
          Free and open source. Needs macOS 14 or later and Ollama installed locally.
        </p>
        <div className="mt-7 flex justify-center">
          <a href="https://github.com/AKaLee-IK27/owlet" className="rounded-[10px] bg-sage-500 px-6 py-3 text-[15px] font-medium text-[#F4F2EA] hover:bg-sage-600">
            Download for macOS
          </a>
        </div>
        <p className="mt-4 text-xs text-ink-2">Requires macOS 14+ · Ollama · Apple Silicon recommended</p>
      </section>

      <footer className="border-t border-paper-3">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-6 py-8 text-sm text-ink-2 sm:flex-row">
          <span className="flex items-center gap-2">
            <Image src="/owlet-logo.png" alt="Owlet logo" width={22} height={24} className="h-[22px] w-auto" />
            Owlet
          </span>
          <div className="flex items-center gap-6">
            <a href="https://github.com/AKaLee-IK27/owlet" className="hover:text-ink-0">GitHub</a>
            <a href="#privacy" className="hover:text-ink-0">Privacy</a>
            <span>A friendly small owl, after the Pokémon Rowlet.</span>
          </div>
        </div>
      </footer>
    </>
  );
}
