import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, cleanup, fireEvent } from "@testing-library/react";
import { WikiMarkdown } from "./WikiMarkdown";

// CLAIM (M24): a task-list checkbox in the reading view is clickable and
// reports the 0-based SOURCE LINE of its `- [ ]` marker + the new checked
// state, so the host can flip exactly the right source line. This guards the
// remark-node-position → source-line mapping that the toggle relies on.

afterEach(cleanup);

const SRC = [
  "# Tasks", // line 0
  "", // line 1
  "- [ ] alpha", // line 2
  "- [x] beta", // line 3
  "- [ ] gamma", // line 4
].join("\n");

describe("WikiMarkdown task checkboxes", () => {
  it("reports the source line + new state on toggle", () => {
    const onToggleTask = vi.fn();
    render(<WikiMarkdown content={SRC} onToggleTask={onToggleTask} />);

    const boxes = screen.getAllByRole("checkbox") as HTMLInputElement[];
    expect(boxes).toHaveLength(3);
    expect(boxes[0].checked).toBe(false);
    expect(boxes[1].checked).toBe(true);

    // Toggle the FIRST unchecked task (source line 2 → check it).
    fireEvent.click(boxes[0]);
    expect(onToggleTask).toHaveBeenCalledWith(2, true);

    // Toggle the checked task (source line 3 → uncheck it).
    fireEvent.click(boxes[1]);
    expect(onToggleTask).toHaveBeenCalledWith(3, false);

    // The last task sits on line 4.
    fireEvent.click(boxes[2]);
    expect(onToggleTask).toHaveBeenCalledWith(4, true);
  });

  it("renders read-only checkboxes that don't flip when no toggle handler is given", () => {
    render(<WikiMarkdown content={SRC} />);
    const boxes = screen.getAllByRole("checkbox") as HTMLInputElement[];
    // readOnly (not disabled) so the box mirrors persisted state; a click never
    // changes it without a wired handler.
    expect(boxes.every((b) => b.readOnly)).toBe(true);
    const before = boxes.map((b) => b.checked);
    boxes.forEach((b) => fireEvent.click(b));
    expect(boxes.map((b) => b.checked)).toEqual(before);
  });
});
