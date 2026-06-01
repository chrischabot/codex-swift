import { MousePointerClick, Type, Camera, Compass, Loader2 } from "lucide-react";

interface Props {
  action: "navigate" | "click" | "type" | "screenshot";
  target: string;
  screenshotUrl?: string;
  status?: "pending" | "done";
}

export function BrowserActionBlock({ action, target, screenshotUrl, status = "done" }: Props) {
  const Icon =
    action === "navigate"   ? Compass :
    action === "click"      ? MousePointerClick :
    action === "type"       ? Type :
    Camera;
  const pending = status === "pending";
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex items-center gap-2 px-3 py-1.5 text-[12.5px]">
        <Icon className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <span className="font-medium capitalize">{action}</span>
        <span className="truncate text-[color:var(--color-text-tertiary)]">{target}</span>
        {pending && (
          <Loader2 className="ml-auto size-3 shrink-0 animate-spin text-[color:var(--color-blue-400)]" />
        )}
      </div>
      {screenshotUrl && (
        <img src={screenshotUrl} alt={action} className="block w-full border-t border-[color:var(--color-divider)]" />
      )}
    </div>
  );
}
