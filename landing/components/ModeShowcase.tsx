import Reveal from "./Reveal";

const MODES = [
  { t: "Clarify", d: "Make goals and constraints explicit." },
  { t: "Add context", d: "Fill in audience, scope, assumptions." },
  { t: "Structured", d: "Role, task, format, constraints." },
  { t: "Compact", d: "Specific, but short." },
];

export default function ModeShowcase() {
  return (
    <section id="modes" className="mx-auto grid max-w-6xl items-center gap-10 px-6 py-20 md:grid-cols-2">
      <Reveal className="rounded-[14px] border border-paper-3 bg-paper-1 p-6">
        <p className="text-xs text-ink-2">Before</p>
        <p className="mt-1 font-display text-[17px] italic text-ink-2">make this email less harsh</p>
        <div className="my-4 h-px bg-paper-3" />
        <p className="text-xs text-ink-2">After (Clarify)</p>
        <p className="mt-1 font-display text-[17px] italic leading-[1.5] text-ink-0">
          Rewrite this email to stay direct but warmer. Keep the ask in the first line and soften the closing.
        </p>
      </Reveal>

      <div>
        <h2 className="font-display text-[32px] font-medium italic text-ink-0">Rewrite the way you mean</h2>
        <p className="mt-3 max-w-[46ch] text-sm leading-relaxed text-ink-1">
          Pick how Owlet should reshape your text. Each mode steers the local model toward a different kind of clarity.
        </p>
        <ul className="mt-6 space-y-3">
          {MODES.map((m) => (
            <li key={m.t} className="flex gap-3">
              <span className="mt-0.5 rounded-full bg-sage-50 px-2.5 py-1 text-xs font-medium text-sage-500">{m.t}</span>
              <span className="text-sm text-ink-1">{m.d}</span>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
