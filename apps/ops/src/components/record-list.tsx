import type { ReactNode } from "react";
import type { InfiniteData, UseInfiniteQueryResult } from "@tanstack/react-query";
import { AlertCircleIcon } from "lucide-react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { problemText } from "@/lib/api";
import { cn } from "@/lib/utils";

export interface Column<T> {
  header: string;
  cell: (row: T) => ReactNode;
  className?: string;
}

/** The same fields as a table row, stacked for a phone. */
export interface Card {
  title: ReactNode;
  status?: ReactNode;
  tags?: ReactNode[];
  meta?: ReactNode[];
  actions?: ReactNode;
}

/**
 * A list of records: a table from tablet width, tappable cards on a phone
 * (a table that scrolls sideways is not a phone layout). Rows open a record
 * with onOpen; cards with their own actions are not themselves buttons.
 */
export function RecordList<T>({
  query,
  columns,
  card,
  rowKey,
  onOpen,
  keep,
  empty,
}: {
  query: UseInfiniteQueryResult<InfiniteData<T[]>>;
  columns: Column<T>[];
  card: (row: T) => Card;
  rowKey: (row: T) => string;
  onOpen?: (row: T) => void;
  /** Shows only the loaded rows it accepts, for a filter the API lacks. */
  keep?: (row: T) => boolean;
  empty: string;
}) {
  if (query.isPending) return <ListSkeleton columns={columns.length} />;
  if (query.isError) {
    return (
      <Alert variant="destructive">
        <AlertCircleIcon />
        <AlertTitle>This list did not load</AlertTitle>
        <AlertDescription className="flex flex-col items-start gap-2">
          <span>{problemText(query.error)}</span>
          <Button variant="outline" size="sm" onClick={() => query.refetch()}>
            Try again
          </Button>
        </AlertDescription>
      </Alert>
    );
  }
  const loaded = query.data.pages.flat();
  const rows = keep ? loaded.filter(keep) : loaded;
  if (rows.length === 0 && !query.hasNextPage) {
    return (
      <Empty className="py-16">
        <EmptyHeader>
          <EmptyTitle>Nothing here</EmptyTitle>
          <EmptyDescription>{empty}</EmptyDescription>
        </EmptyHeader>
      </Empty>
    );
  }
  return (
    <div className={cn("flex flex-col gap-3 transition-opacity", query.isRefetching && !query.isFetchingNextPage && "opacity-60")}>
      <Records rows={rows} columns={columns} card={card} rowKey={rowKey} onOpen={onOpen} />
      {query.hasNextPage ? (
        <div className="flex items-center justify-center gap-3 text-meta text-muted-foreground">
          <span>{keep ? `${rows.length} of ${loaded.length} loaded` : `Showing ${rows.length}`}</span>
          <Button variant="outline" size="sm" disabled={query.isFetchingNextPage} onClick={() => query.fetchNextPage()}>
            {query.isFetchingNextPage ? "Loading…" : "Load more"}
          </Button>
        </div>
      ) : null}
    </div>
  );
}

/** Rows already in hand: a table from tablet width, cards on a phone. */
export function Records<T>({ rows, columns, card, rowKey, onOpen }: { rows: T[]; columns: Column<T>[]; card: (row: T) => Card; rowKey: (row: T) => string; onOpen?: (row: T) => void }) {
  return (
    <>
      <div className="flex flex-col gap-2.5 md:hidden">
        {rows.map((row) => (
          <RecordCard key={rowKey(row)} card={card(row)} onOpen={onOpen ? () => onOpen(row) : undefined} />
        ))}
      </div>
      <div className="hidden md:block">
        <Table>
          <TableHeader>
            <TableRow>
              {columns.map((c) => (
                <TableHead key={c.header} className={c.className}>
                  {c.header}
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow
                key={rowKey(row)}
                tabIndex={onOpen ? 0 : undefined}
                className={cn(onOpen && "cursor-pointer")}
                onClick={onOpen ? (e) => !(e.target as HTMLElement).closest("button, a, input, label") && onOpen(row) : undefined}
                onKeyDown={onOpen ? (e) => e.key === "Enter" && e.target === e.currentTarget && onOpen(row) : undefined}
              >
                {columns.map((c) => (
                  <TableCell key={c.header} className={c.className}>
                    {c.cell(row)}
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </>
  );
}

function RecordCard({ card, onOpen }: { card: Card; onOpen?: () => void }) {
  const body = (
    <>
      <span className="flex items-start justify-between gap-2.5">
        <span className="min-w-0 font-semibold break-words">{card.title}</span>
        {card.status}
      </span>
      {card.tags?.some(Boolean) ? <span className="flex flex-wrap items-center gap-x-2 gap-y-1.5 text-cell">{card.tags.filter(Boolean)}</span> : null}
      {card.meta?.some(Boolean) ? (
        <span className="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-meta text-muted-foreground">
          {card.meta.filter(Boolean).map((m, i) => (
            <span key={i} className="inline-flex items-center gap-1.5">
              {i > 0 ? <span aria-hidden className="opacity-50">·</span> : null}
              {m}
            </span>
          ))}
        </span>
      ) : null}
    </>
  );
  const shell = "flex w-full flex-col gap-2 rounded-xl border bg-card p-3.5 text-left shadow-xs";
  if (onOpen && !card.actions) {
    return (
      <button type="button" onClick={onOpen} className={cn(shell, "transition-colors active:bg-muted")}>
        {body}
      </button>
    );
  }
  return (
    <div className={shell}>
      {body}
      {card.actions ? <div className="flex gap-2 pt-0.5 [&>*]:h-9 [&>*]:flex-1">{card.actions}</div> : null}
    </div>
  );
}

function ListSkeleton({ columns }: { columns: number }) {
  return (
    <div role="status" aria-label="Loading">
      <div className="flex flex-col gap-2.5 md:hidden">
        {Array.from({ length: 4 }, (_, i) => (
          <div key={i} className="flex flex-col gap-2.5 rounded-xl border p-3.5">
            <Skeleton className="h-3.5 w-1/2" />
            <Skeleton className="h-3 w-2/3" />
            <Skeleton className="h-3 w-1/3" />
          </div>
        ))}
      </div>
      <div className="hidden flex-col md:flex">
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="grid gap-4 border-b py-3.5" style={{ gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` }}>
            {Array.from({ length: columns }, (_, j) => (
              <Skeleton key={j} className="h-3" />
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}
