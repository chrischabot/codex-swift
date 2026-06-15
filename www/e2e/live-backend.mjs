// Live backend test: connect to a REAL (isolated) codexd over WSS, call
// wiki/research/start, and assert the job streams wiki/job/event → wiki/job/done.
// Proves codexd's RPC dispatch → subprocess spawn → WS notification path live.
// Usage: node e2e/live-backend.mjs [wss://127.0.0.1:8444/ws]
import WebSocket from "ws";

const URL = process.argv[2] ?? "wss://127.0.0.1:8444/ws";
const ws = new WebSocket(URL, { rejectUnauthorized: false }); // self-signed loopback cert

let nextId = 1;
const pending = new Map();
const events = [];
let jobId = null;
let done = false;

function rpc(method, params) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

const fail = (msg) => { console.error("FAIL:", msg); process.exit(1); };
const timer = setTimeout(() => fail("timeout waiting for wiki/job/done"), 20000);

ws.on("open", async () => {
  try {
    await rpc("initialize", { clientInfo: { name: "livetest", version: "0.1" }, capabilities: { experimentalApi: true } });
    const r = await rpc("wiki/research/start", { topic: "live backend test topic", sources: 2 });
    jobId = r?.jobId;
    if (!jobId) fail("no jobId in wiki/research/start response");
    console.log("started job", jobId);
  } catch (e) { fail("rpc error: " + e.message); }
});

ws.on("message", (raw) => {
  let m; try { m = JSON.parse(raw.toString()); } catch { return; }
  if (m.id !== undefined && m.id !== null && !m.method) {
    const e = pending.get(m.id); if (e) { pending.delete(m.id); m.error ? e.reject(new Error(m.error.message)) : e.resolve(m.result); }
    return;
  }
  if (m.method === "wiki/job/event" || m.method === "wiki/job/done") {
    events.push({ method: m.method, data: m.params?.data });
    console.log(m.method, JSON.stringify(m.params?.data));
    if (m.method === "wiki/job/done") {
      done = true;
      clearTimeout(timer);
      // Assertions: we saw the started + sources + a terminal done.
      const kinds = events.map((e) => e.data?.kind).filter(Boolean);
      const ok = events.some((e) => e.method === "wiki/job/done")
        && kinds.includes("started") && kinds.includes("sources");
      console.log(ok ? "PASS: streamed " + events.length + " events incl. started/sources + done"
                     : "FAIL: missing expected events");
      ws.close();
      process.exit(ok ? 0 : 1);
    }
  }
});

ws.on("error", (e) => fail("ws error: " + e.message));
ws.on("close", () => { if (!done) fail("socket closed before job/done"); });
