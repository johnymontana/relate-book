// Display helpers. No React.

export function compact(n: number): string {
  const abs = Math.abs(n);
  if (abs < 10_000) return Math.round(n).toLocaleString('en-US');
  if (abs < 1_000_000) return `${(n / 1_000).toFixed(abs < 100_000 ? 1 : 0).replace(/\.0$/, '')}K`;
  return `${(n / 1_000_000).toFixed(abs < 10_000_000 ? 1 : 0).replace(/\.0$/, '')}M`;
}

export function integer(n: number): string {
  return Math.round(n).toLocaleString('en-US');
}

export function money(amount: number, currency = 'USD'): string {
  try {
    return new Intl.NumberFormat('en-US', { style: 'currency', currency, maximumFractionDigits: amount >= 1000 ? 0 : 2 }).format(amount);
  } catch {
    return `${currency} ${amount.toFixed(2)}`;
  }
}

export function ms(value: number): string {
  if (value < 1) return `${value.toFixed(2)} ms`;
  if (value < 100) return `${value.toFixed(1)} ms`;
  if (value < 1000) return `${Math.round(value)} ms`;
  return `${(value / 1000).toFixed(value < 10_000 ? 1 : 0)} s`;
}

export function bytes(value: number): string {
  if (value < 1024 * 1024) return `${Math.round(value / 1024)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(value < 10 * 1024 * 1024 ? 1 : 0)} MB`;
  return `${(value / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

export function plural(n: number, one: string, many = `${one}s`): string {
  return `${integer(n)} ${n === 1 ? one : many}`;
}

export function clip(text: string, n: number): string {
  return text.length > n ? `${text.slice(0, n - 1).trimEnd()}…` : text;
}

/** A vector property as the wire carries it. */
export function isVector(value: unknown): value is { dim: number; type: string; values: number[] } {
  return typeof value === 'object' && value !== null && Array.isArray((value as { values?: unknown }).values) && typeof (value as { dim?: unknown }).dim === 'number';
}

/** A point property as the wire carries it. */
export function isPoint(value: unknown): value is { latitude?: number; longitude?: number; x?: number; y?: number; crs: string } {
  return typeof value === 'object' && value !== null && typeof (value as { crs?: unknown }).crs === 'string';
}

/** One property value as text for a table cell or a property list. */
export function formatValue(value: unknown, maxLength = 240): string {
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'string') return clip(value, maxLength);
  if (typeof value === 'number') return Number.isInteger(value) ? String(value) : String(Math.round(value * 10_000) / 10_000);
  if (typeof value === 'boolean') return String(value);
  if (isVector(value)) return `VECTOR<${value.type}>(${value.dim})`;
  if (isPoint(value)) return value.latitude !== undefined ? `point(${value.latitude?.toFixed(4)}, ${value.longitude?.toFixed(4)})` : `point(${value.x}, ${value.y})`;
  if (Array.isArray(value)) return clip(`[${value.map((v) => formatValue(v, 60)).join(', ')}]`, maxLength);
  return clip(JSON.stringify(value), maxLength);
}
