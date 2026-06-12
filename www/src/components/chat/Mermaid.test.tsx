import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { Mermaid } from "./Mermaid";

// Drive the mocked `mermaid.render` via a module-level behavior flag. Using a
// plain async function (not vi.fn) keeps the rejection owned by the awaiting
// component, avoiding vitest's unhandled-rejection detector.
let behavior: { kind: "ok"; svg: string } | { kind: "error"; message: string } = {
  kind: "ok",
  svg: "<svg><g></g></svg>",
};
vi.mock("mermaid", () => ({
  default: {
    initialize: () => {},
    render: async () => {
      if (behavior.kind === "error") throw new Error(behavior.message);
      return { svg: behavior.svg };
    },
  },
}));

describe("Mermaid", () => {
  beforeEach(() => {
    behavior = { kind: "ok", svg: "<svg><g></g></svg>" };
  });

  it("escapes a render error instead of injecting it as HTML (XSS guard)", async () => {
    behavior = { kind: "error", message: '<img src=x onerror="alert(1)">' };
    const { container } = render(<Mermaid content="bad diagram" />);
    // The error text shows up as escaped text…
    expect(await screen.findByText(/img src=x/)).toBeTruthy();
    // …and NOT as a real <img> element parsed from HTML.
    expect(container.querySelector("img")).toBeNull();
  });

  it("renders the trusted SVG on success", async () => {
    behavior = { kind: "ok", svg: "<svg><g></g></svg>" };
    const { container } = render(<Mermaid content="graph TD; A-->B;" />);
    await waitFor(() => expect(container.querySelector("svg")).not.toBeNull());
  });
});
