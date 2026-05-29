import PopupReplica from "./PopupReplica";

export default function Hero() {
  return (
    <section id="hero" className="mx-auto grid max-w-6xl items-center gap-10 px-6 pb-20 pt-10 md:grid-cols-2">
      <div>
        <p className="mb-4 text-xs font-semibold uppercase tracking-[0.08em] text-sage-600">
          Local. Private. macOS.
        </p>
        <h1 className="font-display text-[clamp(40px,6vw,56px)] font-medium italic leading-[1.04] tracking-tight text-ink-0">
          Rewrite anything,<br />right where you are.
        </h1>
        <p className="mt-4 max-w-[42ch] text-base leading-relaxed text-ink-1">
          Select text in any app, press your hotkey, and a model on your own Mac rewrites it clearly. No cloud.
        </p>
        <div className="mt-6 flex items-center gap-2.5">
          <a href="https://github.com/AKaLee-IK27/owlet" className="rounded-[10px] bg-sage-500 px-5 py-3 text-[15px] font-medium text-[#F4F2EA] hover:bg-sage-600">
            Download for macOS
          </a>
          <a href="#how-it-works" className="px-4 py-3 text-[15px] font-medium text-ink-1 hover:text-ink-0">
            See how it works
          </a>
        </div>
      </div>

      <div className="flex justify-center rounded-[20px] bg-[linear-gradient(155deg,#2E5754,#24433f)] p-8 md:p-10">
        <PopupReplica />
      </div>
    </section>
  );
}
