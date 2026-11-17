"use client";

import { useState, type ReactNode } from "react";

export function Card({
  title,
  subtitle,
  table,
  children,
}: {
  title: string;
  subtitle?: string;
  table?: ReactNode;
  children: ReactNode;
}) {
  const [showTable, setShowTable] = useState(false);

  return (
    <section className="rounded-xl bg-surface p-5 ring-1 ring-ring">
      <header className="mb-4 flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold text-ink">{title}</h2>
          {subtitle ? <p className="mt-0.5 text-sm text-ink-2">{subtitle}</p> : null}
        </div>
        {table ? (
          <button
            type="button"
            onClick={() => setShowTable((value) => !value)}
            aria-pressed={showTable}
            className="shrink-0 rounded-md px-2 py-1 text-xs text-ink-2 ring-1 ring-ring hover:bg-page"
          >
            {showTable ? "Chart" : "Table"}
          </button>
        ) : null}
      </header>
      {showTable && table ? table : children}
    </section>
  );
}
