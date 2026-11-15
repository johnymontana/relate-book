const base = { width: 14, height: 14, viewBox: '0 0 16 16', fill: 'none', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round' } as const;

export const SearchIcon = () => (
  <svg {...base} aria-hidden="true">
    <circle cx="7" cy="7" r="4.5" />
    <path d="M10.5 10.5 14 14" />
  </svg>
);

export const BookMark = () => (
  <svg width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="#fff" strokeWidth="1.8" strokeLinejoin="round" aria-hidden="true">
    <path d="M3 3h6a3 3 0 0 1 3 3v7H6a3 3 0 0 0-3-3z" />
  </svg>
);

export const CloseIcon = () => (
  <svg {...base} aria-hidden="true">
    <path d="m4 4 8 8M12 4l-8 8" />
  </svg>
);

export const SendIcon = () => (
  <svg {...base} aria-hidden="true">
    <path d="M2 8h11M9 4l4 4-4 4" />
  </svg>
);

export const StopIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
    <rect x="2" y="2" width="8" height="8" rx="1.5" fill="currentColor" />
  </svg>
);
