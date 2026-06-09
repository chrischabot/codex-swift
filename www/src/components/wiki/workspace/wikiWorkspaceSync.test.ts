import { describe, expect, it } from "vitest";
import {
  CHANNEL_NAME,
  createInProcessChannelHub,
  createWorkspaceSync,
  type WorkspaceSyncMessage,
} from "./wikiWorkspaceSync";
import type { SerializedWorkspace } from "./wikiWorkspace";

const snap = (pageId: string): SerializedWorkspace => ({
  columns: [[{ leaves: [{ type: "page", pageId }], activeIndex: 0 }]],
  activeGroupIndex: 0,
});

describe("createWorkspaceSync", () => {
  it("delivers a posted snapshot to a peer window", async () => {
    const hub = createInProcessChannelHub();
    const a = createWorkspaceSync({ channelFactory: hub.factory, writerId: "A" });
    const b = createWorkspaceSync({ channelFactory: hub.factory, writerId: "B" });
    const received: WorkspaceSyncMessage[] = [];
    b.subscribe((m) => received.push(m));

    a.postWorkspaceUpdated(snap("p1"), 100);
    await hub.flush();

    expect(received).toHaveLength(1);
    expect(received[0].updatedMs).toBe(100);
    expect(received[0].snapshot).toEqual(snap("p1"));
    a.close();
    b.close();
  });

  it("does NOT deliver a window its own echo", async () => {
    const hub = createInProcessChannelHub();
    const a = createWorkspaceSync({ channelFactory: hub.factory, writerId: "A" });
    const own: WorkspaceSyncMessage[] = [];
    a.subscribe((m) => own.push(m));
    a.postWorkspaceUpdated(snap("p1"), 1);
    await hub.flush();
    expect(own).toHaveLength(0);
    a.close();
  });

  it("fans out to multiple peers", async () => {
    const hub = createInProcessChannelHub();
    const a = createWorkspaceSync({ channelFactory: hub.factory, writerId: "A" });
    const b = createWorkspaceSync({ channelFactory: hub.factory, writerId: "B" });
    const c = createWorkspaceSync({ channelFactory: hub.factory, writerId: "C" });
    let bCount = 0;
    let cCount = 0;
    b.subscribe(() => bCount++);
    c.subscribe(() => cCount++);
    a.postWorkspaceUpdated(snap("p1"), 1);
    await hub.flush();
    expect(bCount).toBe(1);
    expect(cCount).toBe(1);
    [a, b, c].forEach((s) => s.close());
  });

  it("a closed peer stops receiving", async () => {
    const hub = createInProcessChannelHub();
    const a = createWorkspaceSync({ channelFactory: hub.factory, writerId: "A" });
    const b = createWorkspaceSync({ channelFactory: hub.factory, writerId: "B" });
    let bCount = 0;
    b.subscribe(() => bCount++);
    b.close();
    a.postWorkspaceUpdated(snap("p1"), 1);
    await hub.flush();
    expect(bCount).toBe(0);
    a.close();
  });

  it("uses the shared channel name", () => {
    expect(CHANNEL_NAME).toBe("wiki:workspace");
  });
});
