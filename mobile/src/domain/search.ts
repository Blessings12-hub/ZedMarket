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

// A readable name for a saved search, built from what the person had selected,
// for example "phone · Electronics · Kabulonga · up to K600".
export function describeSearch(input: {
  term: string;
  categoryName?: string | null;
  areaName?: string | null;
  minPrice?: number | null;
  maxPrice?: number | null;
}): string {
  const parts: string[] = [];
  const term = cleanSearchTerm(input.term);
  if (term.length >= 2) parts.push(term);
  if (input.categoryName) parts.push(input.categoryName);
  if (input.areaName) parts.push(input.areaName);
  const hasMin = input.minPrice !== null && input.minPrice !== undefined;
  const hasMax = input.maxPrice !== null && input.maxPrice !== undefined;
  if (hasMin && hasMax) parts.push(`K${input.minPrice} to K${input.maxPrice}`);
  else if (hasMax) parts.push(`up to K${input.maxPrice}`);
  else if (hasMin) parts.push(`from K${input.minPrice}`);
  return (parts.join(' · ') || 'My search').slice(0, 60);
}
