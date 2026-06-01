import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatRelative(date: Date | string | number): string {
  const ts = typeof date === "object" ? date.getTime() : new Date(date).getTime();
  const diff = (Date.now() - ts) / 1000;
  if (diff < 60) return "now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  if (diff < 86400 * 7) return `${Math.floor(diff / 86400)}d`;
  if (diff < 86400 * 30) return `${Math.floor(diff / (86400 * 7))}w`;
  return `${Math.floor(diff / (86400 * 30))}mo`;
}
