import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, cleanup, fireEvent } from "@testing-library/react";
import { WikiMarkdown } from "./WikiMarkdown";

// CLAIM (M24): a ```mermaid fence renders via the Mermaid component (role=img
// "Mermaid diagram") rather than a syntax-highlighted code block; a non-mermaid
// fence still renders as code. Inline #tags route clicks through onTag (bare,
// no leading #).

afterEach(cleanup);

describe("WikiMarkdown mermaid fence", () => {
  it("renders a mermaid fence through the Mermaid component", () => {
    render(<WikiMarkdown content={"```mermaid\ngraph TD; A-->B;\n```"} />);
    expect(screen.getByRole("img", { name: /mermaid diagram/i })).toBeTruthy();
  });

  it("does not treat a non-mermaid fence as a diagram", () => {
    render(<WikiMarkdown content={"```ts\nconst x = 1;\n```"} />);
    expect(screen.queryByRole("img", { name: /mermaid diagram/i })).toBeNull();
  });
});

describe("WikiMarkdown inline #tags", () => {
  it("routes a clicked #tag through onTag with the bare tag", () => {
    const onTag = vi.fn();
    render(<WikiMarkdown content={"todo for #project/alpha here"} onTag={onTag} />);
    const link = screen.getByText("#project/alpha");
    fireEvent.click(link);
    expect(onTag).toHaveBeenCalledWith("project/alpha");
  });

  it("renders a non-navigating tag when no handler is wired", () => {
    render(<WikiMarkdown content={"a #tag b"} />);
    const link = screen.getByText("#tag") as HTMLAnchorElement;
    // No onTag → not a button role, click is prevented (no navigation).
    expect(link.getAttribute("role")).toBeNull();
  });
});
