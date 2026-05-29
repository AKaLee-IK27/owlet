import Reveal from "./Reveal";

const POINTS = [
  { t: "No cloud", d: "Your text never leaves the machine. There is no server to send it to." },
  { t: "No API keys", d: "Nothing to sign up for, nothing to pay per token." },
  { t: "Your model, your Mac", d: "Runs on Ollama locally. Swap the model whenever you like." },
];

export default function PrivacyBand() {
  return (
    <section id="privacy" className="bg-sage-800 py-20 text-[#EAF2EF]">
      <div className="mx-auto max-w-6xl px-6">
        <h2 className="max-w-[18ch] font-display text-[34px] font-medium italic leading-tight">
          Private by default, because nothing leaves your Mac.
        </h2>
        <div className="mt-10 grid gap-8 md:grid-cols-3">
          {POINTS.map((p, i) => (
            <Reveal key={p.t} delay={i * 0.08}>
              <h3 className="text-lg font-semibold">{p.t}</h3>
              <p className="mt-2 text-sm leading-relaxed text-[#C7DAD5]">{p.d}</p>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
