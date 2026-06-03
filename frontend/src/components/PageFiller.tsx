/** Invisible filler rows that keep a paginated table at a constant height on
 *  every page. Without them, a short last page collapses the table and shifts
 *  the pagination controls (and everything below) up, so the page jumps under
 *  the cursor when navigating between a full and a partial page.
 *
 *  Each filler holds an invisible two-line block mirroring the ticker cell, so
 *  it auto-sizes to exactly one data-row tall in any of these tables — no
 *  magic pixel heights that would drift between tables / row styles. */
export function FillerRows({ count, cols }: { count: number; cols: number }) {
  if (count <= 0) return null;
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <tr key={`filler-${i}`} className="pager-filler" aria-hidden="true">
          <td colSpan={cols}>
            <span className="pager-filler-ghost">
              <strong>&nbsp;</strong>
              <span>&nbsp;</span>
            </span>
          </td>
        </tr>
      ))}
    </>
  );
}
