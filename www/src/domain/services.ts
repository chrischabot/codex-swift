// App data shape shared across the UI. Historically this also defined an
// Effect-backed AppStore (Context/Layer/Ref); phase 3 swapped the substrate for
// a Connector (see src/state/store.ts), leaving the AppStore machinery dead —
// it has been removed along with the `effect` dependency. Only the `AppData`
// type remains (imported by state/store.ts).

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
} from "./models";

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
