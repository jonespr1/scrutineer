"use client";
// Collapsible application sidebar. The collapse preference persists in localStorage and is read on
// the client via useSyncExternalStore, mirroring the theme boot pattern.
//
// HARD fixture: a realistic, mostly-correct React component with ONE buried defect. It is not
// keyword-spottable - finding it requires reasoning about server vs client rendering.

import { useSyncExternalStore, useCallback } from "react";
import Link from "next/link";
import { PanelLeftOpen, PanelLeftClose } from "lucide-react";
import { NAV_ITEMS } from "./nav-config";

const KEY = "sidebar:collapsed";

function subscribe(cb: () => void): () => void {
  window.addEventListener("storage", cb);
  return () => window.removeEventListener("storage", cb);
}

function getSnapshot(): "collapsed" | "expanded" {
  return typeof window !== "undefined" && window.localStorage.getItem(KEY) === "1"
    ? "collapsed"
    : "expanded";
}

function getServerSnapshot(): "collapsed" | "expanded" {
  // The server cannot know a user's saved preference, so it assumes expanded.
  return "expanded";
}

export function AppSidebar({ pathname }: { pathname: string }) {
  const state = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const collapsed = state === "collapsed";

  const toggle = useCallback(() => {
    window.localStorage.setItem(KEY, collapsed ? "0" : "1");
    window.dispatchEvent(new StorageEvent("storage", { key: KEY }));
  }, [collapsed]);

  return (
    <aside className="app-sidebar" data-collapsed={collapsed}>
      <button
        type="button"
        onClick={toggle}
        className="collapse-toggle"
        title={collapsed ? "Expand" : "Collapse"}
        aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
      >
        {collapsed ? <PanelLeftOpen aria-hidden /> : <PanelLeftClose aria-hidden />}
        <span className="label">{collapsed ? "Expand" : "Collapse"}</span>
      </button>

      <nav aria-label="Primary">
        <ul>
          {NAV_ITEMS.map((item) => {
            const active = pathname === item.href || pathname.startsWith(item.href + "/");
            return (
              <li key={item.href}>
                <Link
                  href={item.href}
                  aria-current={active ? "page" : undefined}
                  title={collapsed ? item.label : undefined}
                >
                  <item.icon aria-hidden />
                  {!collapsed && <span className="nav-label">{item.label}</span>}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>
    </aside>
  );
}
