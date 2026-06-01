import React from "react";
import ReactDOM from "react-dom/client";
import "./styles/globals.css";
import { App } from "./app/App";
import { initTheme } from "./lib/theme";

initTheme();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
