import React from 'react';

const palette = ['var(--moss-400)', 'var(--terra-400)', 'var(--sky-500)', 'var(--amber-500)', 'var(--moss-600)'];
function hashName(s = '') { let h = 0; for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0; return h; }
function initials(name = '') {
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] || '') + (parts[1]?.[0] || '')).toUpperCase() || '?';
}

export function Avatar({ name = '', src, size = 'md', status, style, ...rest }) {
  const dims = { xs: 24, sm: 32, md: 40, lg: 56, xl: 72 };
  const dim = dims[size] || dims.md;
  const bg = palette[hashName(name) % palette.length];
  const statusColors = { online: 'var(--success)', relaying: 'var(--terra-400)', offline: 'var(--clay-400)' };
  return (
    <span style={{ position: 'relative', display: 'inline-flex', width: dim, height: dim, ...style }} {...rest}>
      <span style={{
        width: dim, height: dim, borderRadius: '50%', overflow: 'hidden',
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        background: src ? 'var(--clay-200)' : bg, color: '#fff',
        fontFamily: 'var(--font-display)', fontWeight: 'var(--weight-semibold)',
        fontSize: dim * 0.4, userSelect: 'none',
      }}>
        {src ? <img src={src} alt={name} style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : initials(name)}
      </span>
      {status && (
        <span style={{
          position: 'absolute', right: -1, bottom: -1,
          width: dim * 0.3, height: dim * 0.3, borderRadius: '50%',
          background: statusColors[status] || 'var(--clay-400)',
          border: '2px solid var(--surface-card)',
        }} />
      )}
    </span>
  );
}
