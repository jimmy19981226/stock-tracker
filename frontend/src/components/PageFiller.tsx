/** Invisible filler rows that keep a paginated table at a constant height on
 *  every page. Without them, a short last page collapses the table and shifts
 *  the pagination controls (and everything below) up, so the page jumps under
 *  the cursor when navigating between a full and a partial page.
 *
 *  The rows are empty — the `.table-wrap tbody tr { height: 62px }` rule sizes
 *  every data row AND filler to the same height, so a partial page is exactly
 *  as tall as a full one. */
export function FillerRows({ count, cols }: { count: number; cols: number }) {
  if (count <= 0) return null;
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <tr key={`filler-${i}`} className="pager-filler" aria-hidden="true">
          <td colSpan={cols} />
        </tr>
      ))}
    </>
  );
}
