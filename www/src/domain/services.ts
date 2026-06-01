// Effect services that abstract the Codex backend. Phase 2 swaps the in-memory
// Layer for a diminuendo-backed Layer.

import { Context, Effect, Layer, Ref } from "effect";
import type {
  Automation,
  AutomationTemplate,
  Hook,
  McpServer,
  Message,
  Plugin,
  PluginApp,
  Project,
  Skill,
  Thread,
  ThreadStatus,
} from "./models";

let nextId = 1;
const newId = (prefix: string) => `${prefix}-${Date.now().toString(36)}-${nextId++}`;

export interface AppData {
  projects: Project[];
  threads: Thread[];
  messages: Message[];
  plugins: Plugin[];
  apps: PluginApp[];
  automations: Automation[];
  automationTemplates: AutomationTemplate[];
  mcpServers: McpServer[];
  skills: Skill[];
  hooks: Hook[];
}

export class AppStore extends Context.Tag("AppStore")<
  AppStore,
  {
    readonly data: Effect.Effect<AppData>;
    readonly setThreadPinned: (id: string, pinned: boolean) => Effect.Effect<void>;
    readonly setThreadArchived: (id: string, archived: boolean) => Effect.Effect<void>;
    readonly renameThread: (id: string, title: string) => Effect.Effect<void>;
    readonly togglePlugin: (id: string, enabled: boolean) => Effect.Effect<void>;
    readonly addAutomation: (name: string, schedule: string) => Effect.Effect<Automation>;
    readonly deleteAutomation: (id: string) => Effect.Effect<void>;
  }
>() {}

export const makeAppStoreLive = (initial: AppData) =>
  Layer.effect(
    AppStore,
    Effect.gen(function* () {
      const ref = yield* Ref.make<AppData>(initial);
      return {
        data: Ref.get(ref),
        setThreadPinned: (id, pinned) =>
          Ref.update(ref, (s) => ({
            ...s,
            threads: s.threads.map((t) => (t.id === id ? { ...t, pinned } : t)),
          })),
        setThreadArchived: (id, archived) =>
          Ref.update(ref, (s) => ({
            ...s,
            threads: s.threads.map((t) =>
              t.id === id
                ? { ...t, status: (archived ? "archived" : "active") as ThreadStatus }
                : t,
            ),
          })),
        renameThread: (id, title) =>
          Ref.update(ref, (s) => ({
            ...s,
            threads: s.threads.map((t) => (t.id === id ? { ...t, title } : t)),
          })),
        togglePlugin: (id, enabled) =>
          Ref.update(ref, (s) => ({
            ...s,
            apps: s.apps.map((a) => (a.id === id ? { ...a, enabled } : a)),
          })),
        addAutomation: (name, schedule) =>
          Effect.gen(function* () {
            const auto: Automation = { id: newId("auto"), name, schedule };
            yield* Ref.update(ref, (s) => ({ ...s, automations: [...s.automations, auto] }));
            return auto;
          }),
        deleteAutomation: (id) =>
          Ref.update(ref, (s) => ({
            ...s,
            automations: s.automations.filter((a) => a.id !== id),
          })),
      };
    }),
  );
