import { useState } from 'react';

/** A book cover, hot-linked from Open Library or Amazon, with an initial as the fallback. */
export function Cover({ src, title, large = false }: { src: string | null | undefined; title: string; large?: boolean }) {
  const [failed, setFailed] = useState(false);
  const className = large ? 'cover large' : 'cover';
  if (!src || failed) {
    return (
      <div className={className} aria-hidden="true">
        {title.trim().charAt(0).toUpperCase() || '?'}
      </div>
    );
  }
  return <img className={className} src={src.replace(/^http:/, 'https:')} alt="" loading="lazy" decoding="async" referrerPolicy="no-referrer" onError={() => setFailed(true)} />;
}
