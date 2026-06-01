import {
  FileText,
  FileCode,
  FileJson,
  FileType,
  FileCog,
  Braces,
  Hash,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";

// Language-aware file icon picker, mirroring the original
// output/webview/get-file-icon-BjbD1TxH.js which chooses an icon per file
// extension rather than rendering a generic document for every row.
export function getFileIcon(name: string): LucideIcon {
  const ext = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1).toLowerCase() : "";
  switch (ext) {
    case "ts":
    case "tsx":
    case "js":
    case "jsx":
    case "mjs":
    case "cjs":
      return FileCode;
    case "json":
      return FileJson;
    case "css":
    case "scss":
    case "less":
      return Hash;
    case "md":
    case "mdx":
    case "txt":
      return FileType;
    case "yml":
    case "yaml":
    case "toml":
    case "ini":
    case "env":
      return FileCog;
    case "html":
    case "xml":
    case "svg":
      return Braces;
    default:
      return FileText;
  }
}
