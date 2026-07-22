import React from 'react';

export function Dialog({ open = true, title, children, footer, onClose, width = 460, style, ...rest }) {
  if (!open) return null;
  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 1000,
        display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 'var(--space-5)',
        background: 'rgba(36, 28, 21, 0.45)', backdropFilter: 'blur(3px)',
        animation: 'gl-fade var(--dur-normal) var(--ease-out)',
      }}
    >
      <div
        role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}
        style={{
          width: '100%', maxWidth: width, background: 'var(--surface-card)',
          borderRadius: 'var(--radius-xl)', boxShadow: 'var(--shadow-xl)',
          animation: 'gl-pop var(--dur-normal) var(--ease-spring)',
          overflow: 'hidden', ...style,
        }}
        {...rest}
      >
        <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12, padding: 'var(--space-5) var(--space-5) 0' }}>
          {title && <h2 style={{ margin: 0, fontFamily: 'var(--font-display)', fontSize: 'var(--text-xl)', fontWeight: 'var(--weight-bold)', color: 'var(--text-strong)', letterSpacing: 'var(--tracking-tight)' }}>{title}</h2>}
          {onClose && (
            <button type="button" onClick={onClose} aria-label="Close" style={{ border: 'none', background: 'transparent', cursor: 'pointer', color: 'var(--text-subtle)', display: 'flex', padding: 4, margin: -4 }}>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
            </button>
          )}
        </div>
        <div style={{ padding: 'var(--space-4) var(--space-5)', fontFamily: 'var(--font-sans)', fontSize: 'var(--text-md)', color: 'var(--text-body)', lineHeight: 'var(--leading-normal)' }}>{children}</div>
        {footer && <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 'var(--space-3)', padding: '0 var(--space-5) var(--space-5)' }}>{footer}</div>}
      </div>
      <style>{`@keyframes gl-fade{from{opacity:0}to{opacity:1}}@keyframes gl-pop{from{opacity:0;transform:translateY(8px) scale(0.97)}to{opacity:1;transform:none}}`}</style>
    </div>
  );
}
