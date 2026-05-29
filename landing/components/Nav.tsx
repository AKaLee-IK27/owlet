import Image from "next/image";

export default function Nav() {
  return (
    <nav className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
      <a href="#hero" className="flex items-center gap-2.5 font-semibold tracking-tight text-ink-0">
        <Image src="/owlet-logo.png" alt="Owlet logo" width={30} height={33} className="h-[30px] w-auto" priority />
        Owlet
      </a>
      <div className="flex items-center gap-7 text-sm text-ink-1">
        <a href="#how-it-works" className="hover:text-ink-0">How it works</a>
        <a href="#privacy" className="hover:text-ink-0">Privacy</a>
        <a
          href="https://github.com/AKaLee-IK27/owlet"
          className="rounded-lg bg-sage-500 px-4 py-2 font-medium text-[#F4F2EA] hover:bg-sage-600"
        >
          Download
        </a>
      </div>
    </nav>
  );
}
