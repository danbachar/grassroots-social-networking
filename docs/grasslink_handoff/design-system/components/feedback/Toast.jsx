import React from 'react';

export function Toast({ title, message, tone = 'neutral', icon, onDismiss, style, ...rest }) {
  const accents = {
    neutral: 'var(--clay-400)', primary: 'var(--primary)', success: 'var(--success)',
    warning: 'var(--warning)', danger: 'var(--danger)', info: 'var(--info)',
  };
  return (
    <div role="status" style={{
      display: 'flex', alignItems: 'flex-start', gap: 12,
      background: 'var(--surface-card)', borderRadius: 'var(--radius-lg)',
      border: '1px solid var(--border-subtle)', boxShadow: 'var(--shadow-lg)',
      padding: '14px 16px', maxWidth: 380, position: 'relative', overflow: 'hidden',
      ...style,
    }} {...rest}>
      <span style={{ position: 'absolute', left: 0, top: 0, bottom: 0, width: 4, background: accents[tone] || accents.neutral }} />
      {icon && <span style={{ display: 'flex', color: accents[tone] || accents.neutral, marginTop: 1 }}>{icon}</span>}
      <div style={{ flex: 1, minWidth: 0 }}>
        {title && <div style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-md)', fontWeight: 'var(--weight-semibold)', color: 'var(--text-strong)' }}>{title}</div>}
        {message && <div style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', color: 'var(--text-muted)', marginTop: 2, lineHeight: 'var(--leading-normal)' }}>{message}</div>}
      </div>
      {onDismiss && (
        <button type="button" onClick={onDismiss} aria-label="Dismiss" style={{
          border: 'none', background: 'transparent', cursor: 'pointer', color: 'var(--text-subtle)',
          display: 'flex', padding: 2, marginTop: 1,
        }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>
      )}
    </div>
  );
}
