import { useRuntime } from "@/runtime/RuntimeProvider";
import { Loader2, AlertCircle } from "lucide-react";
import { cn } from "@/lib/utils";

// Mirrors the thread-level remote-connection badge (app-server-connection-state.js
// `_` indicator map + `v` class map): connecting/restarting render an animated
// spinner, connected/disconnected render an 8px (size-2) dot, error renders an
// error icon. The runtime here exposes connecting / reconnecting / connected /
// error / offline; reconnecting maps to the original "restarting" spinner and
// offline maps to "disconnected". Colors now use the defined charts tokens
// (original `v` map: restarting=text-charts-blue, connected=text-charts-green,
// error=text-charts-red).
export function ConnectionStatus() {
  const { status } = useRuntime();

  let indicator: React.ReactNode;
  let label: string;

  switch (status.kind) {
    case "connecting":
      // Original "connecting": text-token-description-foreground spinner.
      indicator = (
        <Loader2 className="size-3 animate-spin text-[color:var(--color-text-tertiary)]" />
      );
      label = "Connecting";
      break;
    case "reconnecting":
      // Original "restarting": text-token-charts-blue spinner.
      indicator = (
        <Loader2 className="size-3 animate-spin text-charts-blue" />
      );
      label = "Restarting";
      break;
    case "connected":
      // Original "connected": size-2 rounded-full dot tinted text-token-charts-green.
      indicator = (
        <span aria-hidden className="block size-2 rounded-full bg-charts-green" />
      );
      label = status.clientId ?? "Connected";
      break;
    case "error":
      // Original "error": text-token-charts-red icon.
      indicator = <AlertCircle className="size-3 text-charts-red" />;
      label = "Error";
      break;
    case "offline":
    default:
      // Original "disconnected": size-2 rounded-full dot tinted text-token-description-foreground.
      indicator = (
        <span
          aria-hidden
          className="block size-2 rounded-full bg-[color:var(--color-text-quaternary)]"
        />
      );
      label = "Disconnected";
      break;
  }

  return (
    <div
      className={cn(
        "flex items-center gap-1.5 px-2 text-[11px] text-[color:var(--color-text-tertiary)]",
      )}
    >
      {indicator}
      <span>{label}</span>
    </div>
  );
}
