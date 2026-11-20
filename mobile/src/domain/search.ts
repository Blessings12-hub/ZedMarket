const MAX_TERM_LENGTH = 60;

// PostgREST reads commas, brackets and quotes inside an .or() filter as syntax,
// and % and _ are wildcards in ilike. Strip them so a search box cannot change the query.
export function cleanSearchTerm(raw: string): string {
  return raw
    .replace(/[,()"'\\%*_]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_TERM_LENGTH);
}

export function searchFilter(raw: string): string | null {
  const term = cleanSearchTerm(raw);
  if (term.length < 2) return null;
  return `title.ilike.%${term}%,description.ilike.%${term}%`;
}
