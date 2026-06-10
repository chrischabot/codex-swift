import { describe, it, expect, afterEach } from "vitest";
import { render, screen, cleanup, fireEvent } from "@testing-library/react";
import { Callout } from "./Callout";

// CLAIM (M24): a callout with a fold marker (`+`/`-`) is collapsible — the
// title becomes a toggle button, the body hides when collapsed, and the initial
// state follows the marker (`-` starts collapsed). A non-foldable callout (fold
// null) shows a static header with no button.

afterEach(cleanup);

describe("Callout fold", () => {
  it("renders a static header (no button) when not foldable", () => {
    render(
      <Callout type="note" title="Heads up" fold={null}>
        <p>body text</p>
      </Callout>,
    );
    expect(screen.queryByRole("button")).toBeNull();
    expect(screen.getByText("body text")).toBeTruthy();
  });

  it("starts open for `+` and toggles closed/open", () => {
    render(
      <Callout type="tip" title="Open me" fold="+">
        <p>secret</p>
      </Callout>,
    );
    const btn = screen.getByRole("button");
    expect(btn.getAttribute("aria-expanded")).toBe("true");
    expect(screen.getByText("secret")).toBeTruthy();
    fireEvent.click(btn);
    expect(btn.getAttribute("aria-expanded")).toBe("false");
    expect(screen.queryByText("secret")).toBeNull();
    fireEvent.click(btn);
    expect(screen.getByText("secret")).toBeTruthy();
  });

  it("starts collapsed for `-`", () => {
    render(
      <Callout type="warning" title="Closed" fold="-">
        <p>hidden body</p>
      </Callout>,
    );
    expect(screen.getByRole("button").getAttribute("aria-expanded")).toBe("false");
    expect(screen.queryByText("hidden body")).toBeNull();
  });
});
