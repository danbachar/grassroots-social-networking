import React from 'react';

export function Tag({ children, onRemove, icon, style, ...rest }) {
  const [hover, setHover] = React.useState(false);
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 6,
      background: 'var(--surface-card)', color: 'var(--text-body)',
      border: '1px solid var(--border-default)',
      fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', fontWeight: 'var(--weight-medium)',
      padding: onRemove ? '5px 6px 5px 12px' : '5px 12px', borderRadius: 'var(--radius-pill)',
      ...style,
    }} {...rest}>
      {icon && <span style={{ display: 'flex', color: 'var(--text-subtle)' }}>{icon}</span>}
      {children}
      {onRemove && (
        <button type="button" onClick={onRemove}
          onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
          aria-label="Remove"
          style={{
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            width: 18, height: 18, borderRadius: '50%', border: 'none', cursor: 'pointer',
            background: hover ? 'var(--clay-200)' : 'transparent', color: 'var(--text-muted)',
            transition: 'background var(--dur-fast) var(--ease-out)',
          }}>
          <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>
      )}
    </span>
  );
}
