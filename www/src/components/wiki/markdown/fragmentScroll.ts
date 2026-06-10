// Fragment scroll + flash for the wiki reading view.
//
// A wikilink `[[Page#Heading]]` / `[[Page#^block]]` opens the target page and
// passes the suffix (`Heading` or `^block`) as a fragment. After the body has
// rendered we resolve that fragment to a DOM anchor and scroll/flash it:
//   - a heading slugs to the same id rehypeHeadingIds assigns (matches the
//     outline panel + intra-page links), so we can scroll by id directly;
//   - a `^block` maps to the `block-<id>` element id that remarkBlockIds hoists.
// We also tolerate a raw slug/element id (so `#some-heading` works verbatim).

import { slugify } from "./wikiRemarkPlugins";

const FLASH_MS = 1500;

// Flash via inline styles (not a CSS class) so this stays self-contained and
// does not depend on a rule in the shared wiki stylesheet. A faint accent wash
// fades out over ~1.5s; the original inline values are restored afterward.
function flash(el: HTMLElement): void {
  el.scrollIntoView({ block: "start", behavior: "smooth" });
  const prevBg = el.style.backgroundColor;
  const prevTransition = el.style.transition;
  const prevRadius = el.style.borderRadius;
  el.style.transition = "background-color 1.2s ease-out";
  el.style.borderRadius = prevRadius || "var(--radius-md, 6px)";
  el.style.backgroundColor =
    "color-mix(in srgb, var(--text-link) 22%, transparent)";
  // Next frame: fade back to transparent so the transition animates.
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(() => {
      el.style.backgroundColor = "transparent";
    });
  });
  window.setTimeout(() => {
    el.style.backgroundColor = prevBg;
    el.style.transition = prevTransition;
    el.style.borderRadius = prevRadius;
  }, FLASH_MS);
}

/**
 * Scroll to + flash the element matching `fragment` within `root`. The leading
 * `#` is optional. A `^block` fragment resolves to `#block-<id>`; otherwise we
 * try the verbatim id, then the slugified id (heading), then a case-insensitive
 * heading-text match as a last resort. No-op when nothing matches.
 */
export function scrollToFragment(root: HTMLElement, fragment: string | null | undefined): void {
  if (!fragment) return;
  let frag = fragment.trim();
  if (frag.startsWith("#")) frag = frag.slice(1);
  if (frag.length === 0) return;

  const byId = (id: string): HTMLElement | null => {
    // Scope the lookup to `root` (not document) — a page can be open in
    // multiple panes, and getElementById would grab the first global match.
    try {
      return root.querySelector<HTMLElement>(`#${CSS.escape(id)}`);
    } catch {
      return null;
    }
  };

  if (frag.startsWith("^")) {
    const el = byId(`block-${frag.slice(1)}`);
    if (el) flash(el);
    return;
  }

  // 1) verbatim id (already-slugged fragment), 2) slugified (heading text).
  const direct = byId(frag) ?? byId(slugify(frag));
  if (direct) {
    flash(direct);
    return;
  }

  // 3) fall back to a case-insensitive heading-text match.
  const wanted = frag.toLowerCase();
  for (const h of root.querySelectorAll<HTMLElement>("h1, h2, h3, h4, h5, h6")) {
    if ((h.textContent ?? "").trim().toLowerCase() === wanted) {
      flash(h);
      return;
    }
  }
}
