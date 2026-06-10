import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { scrollToFragment } from "./fragmentScroll";

// CLAIM (M25): scrollToFragment resolves a `[[Page#frag]]` suffix to a DOM
// anchor inside the reading root — a heading by slugged id (or text), a
// `^block` to its `block-<id>` element — scrolls it into view, and briefly
// flashes it. A non-matching fragment is a no-op. Lookup is scoped to the root.

describe("scrollToFragment", () => {
  let root: HTMLElement;
  let scrollSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    scrollSpy = vi.fn();
    // jsdom doesn't implement scrollIntoView.
    Element.prototype.scrollIntoView = scrollSpy as unknown as typeof Element.prototype.scrollIntoView;
    root = document.createElement("div");
    root.innerHTML = `
      <h2 id="my-heading">My Heading</h2>
      <p id="block-abc-1">a block</p>
      <h3>Plain Text Only</h3>
    `;
    document.body.appendChild(root);
    vi.useFakeTimers();
  });
  afterEach(() => {
    document.body.innerHTML = "";
    vi.useRealTimers();
  });

  it("scrolls to a heading by slugged id", () => {
    scrollToFragment(root, "My Heading");
    expect(scrollSpy).toHaveBeenCalledOnce();
  });

  it("accepts a leading # and a verbatim slug id", () => {
    scrollToFragment(root, "#my-heading");
    expect(scrollSpy).toHaveBeenCalledOnce();
  });

  it("resolves a ^block fragment to its block-<id> anchor", () => {
    scrollToFragment(root, "^abc-1");
    expect(scrollSpy).toHaveBeenCalledOnce();
  });

  it("falls back to case-insensitive heading text match", () => {
    scrollToFragment(root, "plain text only");
    expect(scrollSpy).toHaveBeenCalledOnce();
  });

  it("is a no-op for an unknown fragment or empty input", () => {
    scrollToFragment(root, "nope-not-here");
    scrollToFragment(root, "");
    scrollToFragment(root, null);
    expect(scrollSpy).not.toHaveBeenCalled();
  });

  it("flashes the target then restores after the timeout", () => {
    const h = root.querySelector<HTMLElement>("#my-heading")!;
    scrollToFragment(root, "my-heading");
    // a wash is applied (non-empty inline background during the flash window)
    expect(h.style.transition).toContain("background-color");
    vi.advanceTimersByTime(2000);
    expect(h.style.backgroundColor).toBe("");
  });
});
