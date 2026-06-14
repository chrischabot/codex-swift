import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { HotkeysProvider } from "@tanstack/react-hotkeys";
import { TooltipProvider } from "@/components/ui/tooltip";
import { RuntimeProvider } from "@/runtime/RuntimeProvider";
import { makeCodexConnector } from "@/runtime/connector-codex";
import { makeMockConnector } from "@/runtime/connector-mock";
import { AppShell } from "./AppShell";

// Default to the real codex-swift gateway (same-origin /ws). Set
// VITE_CONNECTOR=mock at build time to use the in-memory seed/simulator.
const connectorFactory =
  import.meta.env.VITE_CONNECTOR === "mock" ? makeMockConnector : makeCodexConnector;
import { HomePage } from "@/pages/HomePage";
import { ThreadPage } from "@/pages/ThreadPage";
import { PluginsPage } from "@/pages/PluginsPage";
import { PluginsManagePage } from "@/pages/PluginsManagePage";
import { PluginDetailPage } from "@/pages/PluginDetailPage";
import { AutomationsPage } from "@/pages/AutomationsPage";
import { SettingsPage } from "@/pages/SettingsPage";
import { ArchivePage } from "@/pages/ArchivePage";
import { AutomationEditPage } from "@/pages/AutomationEditPage";
import { WikiPage } from "@/pages/WikiPage";
import { WikiGraphPage } from "@/pages/WikiGraphPage";
import { WikiPropertiesPage } from "@/pages/WikiPropertiesPage";
import { WikiConsolePage } from "@/pages/WikiConsolePage";
import { WikiEnrichView } from "@/components/wiki/WikiEnrichView";

export function App() {
  return (
    <RuntimeProvider factory={connectorFactory}>
    <HotkeysProvider>
    <TooltipProvider delayDuration={250}>
      <BrowserRouter>
        <Routes>
          <Route element={<AppShell />}>
            <Route index element={<Navigate to="/home/p-diminuendo" replace />} />
            <Route path="home/:projectId?" element={<HomePage />} />
            <Route path="thread/:threadId" element={<ThreadPage />} />
            <Route path="plugins" element={<PluginsPage />} />
            <Route path="plugins/manage" element={<PluginsManagePage />} />
            <Route path="plugins/:pluginId" element={<PluginDetailPage />} />
            <Route path="automations" element={<AutomationsPage />} />
            <Route path="automations/:automationId" element={<AutomationEditPage />} />
            <Route path="wiki" element={<WikiPage />} />
            <Route path="wiki/graph" element={<WikiGraphPage />} />
            <Route path="wiki/console" element={<WikiConsolePage />} />
            <Route path="wiki/properties" element={<WikiPropertiesPage />} />
            <Route path="wiki/enrich" element={<WikiEnrichView />} />
            <Route path="wiki/:pageId" element={<WikiPage />} />
            <Route path="settings" element={<SettingsPage />} />
            <Route path="archive" element={<ArchivePage />} />
          </Route>
        </Routes>
      </BrowserRouter>
    </TooltipProvider>
    </HotkeysProvider>
    </RuntimeProvider>
  );
}
