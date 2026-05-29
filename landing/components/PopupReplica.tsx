import Image from "next/image";

export default function PopupReplica() {
  return (
    <div className="w-[420px] max-w-full rounded-[14px] border border-paper-3 bg-paper-0/95 p-4 shadow-[0_24px_60px_rgba(20,40,38,0.35)]">
      <div className="mb-2.5 flex items-center gap-2">
        <Image src="/owlet-logo.png" alt="" width={18} height={20} className="h-5 w-auto" />
        <span className="text-xs font-medium text-ink-1">Improve prompt</span>
        <span className="ml-auto font-mono text-[10px] text-ink-2">⌥ Space</span>
        <span className="grid h-[22px] w-[22px] place-items-center text-[11px] text-ink-2">✕</span>
      </div>

      <p className="mb-3 font-display text-[17px] italic leading-[1.5] text-ink-0">
        <span className="text-diff-removed line-through">write me a blog post about ai</span>{" "}
        <span className="text-diff-added">
          Write a 600-word post for engineers on practical local-LLM workflows, with one concrete example per use case.
        </span>
      </p>

      <div className="mb-3 flex flex-wrap gap-1">
        <span className="rounded-full bg-sage-50 px-2.5 py-1 text-xs font-medium text-sage-500">Clarify</span>
        <span className="rounded-full px-2.5 py-1 text-xs font-medium text-ink-1">Add context</span>
        <span className="rounded-full px-2.5 py-1 text-xs font-medium text-ink-1">Structured</span>
        <span className="rounded-full px-2.5 py-1 text-xs font-medium text-ink-1">Compact</span>
      </div>

      <div className="flex items-center gap-1.5">
        <button className="rounded-lg bg-sage-500 px-4 py-1.5 text-[13px] font-medium text-[#F4F2EA]">Replace</button>
        <span className="rounded-lg px-3 py-1.5 text-[13px] font-medium text-ink-1">Try again</span>
        <span className="ml-auto flex items-center gap-1.5 text-[13px] text-ink-2">⧉ Copy</span>
      </div>
    </div>
  );
}
