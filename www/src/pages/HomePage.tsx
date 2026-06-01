import { useParams, useNavigate } from "react-router-dom";
import { useAppData, dispatch } from "@/state/store";
import { Composer } from "@/components/composer/Composer";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export function HomePage() {
  const { projectId } = useParams();
  const { projects } = useAppData();
  const navigate = useNavigate();
  const project = projects.find((p) => p.id === projectId) ?? projects[0];

  // Mirrors the original home hero heading logic (app-main part-02 entity aT):
  // git repos read "What should we build in <name>?" with the inline,
  // clickable project name; plain projects (or an absent/over-long name) drop
  // the inline name and fall back to the short "What should we build?" form.
  const name = project?.name ?? "";
  const isGit = project?.kind === "git";
  const tooLong = !isGit || name.length === 0 || name.length > 15;

  // Inline project name rendered as a clickable project-select affordance,
  // matching the original `oT`/hero trigger button with hover/active overlay.
  const projectSelect = (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          className="relative z-0 inline-block cursor-pointer whitespace-pre after:absolute after:-inset-x-1.5 after:-inset-y-0 after:-z-10 after:rounded-xl after:content-[''] group-hover/title:after:bg-[color:var(--foreground)]/5 hover:after:bg-[color:var(--foreground)]/10 data-[state=open]:after:bg-[color:var(--foreground)]/5 data-[state=open]:hover:after:bg-[color:var(--foreground)]/10"
        >
          {name}
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start">
        {projects.map((p) => (
          <DropdownMenuItem key={p.id} onSelect={() => navigate(`/home/${p.id}`)}>
            {p.name}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );

  const heading = tooLong ? (
    <>What should we build?</>
  ) : (
    <>What should we build in {projectSelect}?</>
  );

  return (
    <div className="@container/left-panel relative flex h-full flex-col">
      <div className="relative flex w-full flex-1 flex-col overflow-y-auto">
        <div className="mx-auto flex min-h-full w-full min-w-0 max-w-[720px] flex-col px-6 py-6">
          <div className="grid min-h-0 min-w-0 flex-1 grid-rows-[minmax(8rem,39%)_auto_minmax(0,1fr)]">
            {/* Hero heading (top region) */}
            <div className="heading-xl flex max-w-full min-w-0 select-none items-end justify-center whitespace-pre-wrap pb-11 text-center text-[28px] font-medium leading-[1.2] text-foreground">
              <span className="group/title inline-block max-w-full">{heading}</span>
            </div>

            {/* Composer */}
            <div className="flex min-w-0 flex-col gap-2 pb-2">
              {/* home-banners region — empty by default (upgrade CTA / Get Plus) */}
              <div className="home-banners mt-2 flex flex-col gap-2 empty:hidden" />
              <Composer
                project={project?.name}
                onSubmit={async (text, opts) => {
                  const t = await dispatch.createThread(project?.id ?? null, truncate(text));
                  await dispatch.sendMessage(t.id, text, opts);
                  navigate(`/thread/${t.id}`);
                }}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function truncate(s: string, n = 60) {
  const oneLine = s.replace(/\n/g, " ").trim();
  return oneLine.length > n ? oneLine.slice(0, n - 1).trimEnd() + "…" : oneLine;
}
