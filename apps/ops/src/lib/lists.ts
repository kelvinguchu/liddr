import { useInfiniteQuery } from "@tanstack/react-query";

/** Rows per page, the API's default limit. */
export const PAGE = 50;

/** A list read in pages of PAGE. Load more fetches the next one. */
export function usePagedList<T>(key: readonly unknown[], load: (limit: number, offset: number) => Promise<T[]>) {
  return useInfiniteQuery({
    queryKey: key,
    queryFn: ({ pageParam }) => load(PAGE, pageParam),
    initialPageParam: 0,
    getNextPageParam: (last, all) => (last.length === PAGE ? all.length * PAGE : undefined),
  });
}
