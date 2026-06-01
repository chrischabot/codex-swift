export function SidebarSectionHeader({ label }: { label: string }) {
  return (
    <div className="px-2 pb-1 pt-2 text-[11px] font-medium text-[color:var(--color-muted-foreground)]">
      {label}
    </div>
  );
}
