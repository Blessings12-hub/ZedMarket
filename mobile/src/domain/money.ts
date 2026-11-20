const MAX_PRICE = 99_999_999.99;

export function formatKwacha(amount: number): string {
  const text = Number.isInteger(amount)
    ? amount.toLocaleString('en-US')
    : amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return `K${text}`;
}

// Accepts "2,500", "K2500", "ZMW 2500.50". Returns null for anything that is not a usable price.
export function parsePrice(input: string): number | null {
  const cleaned = input
    .trim()
    .replace(/^(zmw|k)\s*/i, '')
    .replace(/[,\s]/g, '');

  if (!/^\d+(\.\d{1,2})?$/.test(cleaned)) return null;

  const value = Number(cleaned);
  if (value <= 0 || value > MAX_PRICE) return null;
  return value;
}
