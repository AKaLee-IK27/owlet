import Reveal from "./Reveal";

const STEPS = [
  { n: "1", t: "Select text", d: "Highlight a draft, a prompt, or a paragraph in any app." },
  { n: "2", t: "Press ⌥ Space", d: "Owlet reads the selection and asks your local model to rewrite it." },
  { n: "3", t: "Replace or Copy", d: "Review the inline diff, then drop it in place or copy it out." },
];

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="mx-auto max-w-6xl px-6 py-20">
      <h2 className="mb-10 font-display text-[32px] font-medium italic text-ink-0">How it works</h2>
      <div className="grid gap-5 md:grid-cols-3">
        {STEPS.map((s, i) => (
          <Reveal key={s.n} delay={i * 0.08} className="rounded-[14px] border border-paper-3 bg-paper-1 p-6">
            <div className="grid h-9 w-9 place-items-center rounded-lg bg-sage-50 text-[15px] font-semibold text-sage-600">
              {s.n}
            </div>
            <h3 className="mt-4 text-[17px] font-semibold text-ink-0">{s.t}</h3>
            <p className="mt-2 text-sm leading-relaxed text-ink-1">{s.d}</p>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
