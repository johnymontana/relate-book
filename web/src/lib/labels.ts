// How node labels look in the graph. Eight labels get the eight categorical
// hues (in the reference palette's validated order); the rest fold into
// neutrals. Identity never rests on colour alone: every node carries a
// caption, and the legend and the detail panel name the label.

import { captionKey } from '../engine/schema';
import type { WireNode } from '../engine/wire';
import { clip } from './format';

interface LabelStyle {
  light: string;
  dark: string;
  size: number;
}

const STYLES: Record<string, LabelStyle> = {
  Book: { light: '#2a78d6', dark: '#3987e5', size: 40 },
  Author: { light: '#eb6834', dark: '#d95926', size: 32 },
  Subject: { light: '#1baf7a', dark: '#199e70', size: 28 },
  Place: { light: '#eda100', dark: '#c98500', size: 30 },
  Person: { light: '#e87ba4', dark: '#d55181', size: 28 },
  Genre: { light: '#008300', dark: '#0ca30c', size: 32 },
  Award: { light: '#6250d6', dark: '#9085e9', size: 30 },
  Series: { light: '#e34948', dark: '#e66767', size: 32 },
  Wishlist: { light: '#52514e', dark: '#c3c2b7', size: 42 },
  Edition: { light: '#898781', dark: '#898781', size: 28 },
  Item: { light: '#898781', dark: '#898781', size: 28 },
  Publisher: { light: '#a8a69e', dark: '#6b6a65', size: 28 },
  Era: { light: '#a8a69e', dark: '#6b6a65', size: 28 },
  Country: { light: '#a8a69e', dark: '#6b6a65', size: 30 },
};

const FALLBACK: LabelStyle = { light: '#a8a69e', dark: '#6b6a65', size: 28 };

/** The label a node is drawn as: the most specific one the app knows. */
export function primaryLabel(labels: string[]): string {
  if (labels.includes('Edition')) return 'Edition';
  return labels.find((l) => l in STYLES) ?? labels[0] ?? 'Node';
}

export function labelColor(label: string, dark: boolean): string {
  const style = STYLES[label] ?? FALLBACK;
  return dark ? style.dark : style.light;
}

export function labelSize(label: string): number {
  return (STYLES[label] ?? FALLBACK).size;
}

export function nodeCaption(node: WireNode, max = 28): string {
  const key = captionKey(node.labels);
  const value = node.properties[key] ?? node.properties.name ?? node.properties.title ?? node.properties.key ?? node.properties.id;
  return typeof value === 'string' || typeof value === 'number' ? clip(String(value), max) : primaryLabel(node.labels);
}

export const LEGEND_ORDER = ['Book', 'Author', 'Subject', 'Genre', 'Place', 'Person', 'Award', 'Series', 'Era', 'Country', 'Publisher', 'Edition', 'Item', 'Wishlist'];
