import Reveal from "./Reveal";
import {
  NotePencil, ChatCircleText, FileText, GoogleChromeLogo, Code, EnvelopeSimple,
} from "@phosphor-icons/react/dist/ssr";

const APPS = [
  { Icon: NotePencil, label: "TextEdit" },
  { Icon: ChatCircleText, label: "Slack" },
  { Icon: FileText, label: "Notion" },
  { Icon: GoogleChromeLogo, label: "Chrome" },
  { Icon: Code, label: "VS Code" },
  { Icon: EnvelopeSimple, label: "Mail" },
];

export default function AppGrid() {
  return (
    <section id="apps" className="mx-auto max-w-6xl px-6 py-20">
      <h2 className="font-display text-[32px] font-medium italic text-ink-0">Works in every app</h2>
      <p className="mt-3 max-w-[52ch] text-sm leading-relaxed text-ink-1">
        Owlet reads your selection directly where it can, and falls back to the clipboard everywhere else. So it works in native apps, browsers, and Electron alike.
      </p>
      <div className="mt-10 grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-6">
        {APPS.map((a, i) => (
          <Reveal key={a.label} delay={i * 0.05} className="flex flex-col items-center gap-2 rounded-[14px] border border-paper-3 bg-paper-1 py-6">
            <a.Icon size={28} weight="duotone" className="text-sage-600" />
            <span className="text-xs text-ink-1">{a.label}</span>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
