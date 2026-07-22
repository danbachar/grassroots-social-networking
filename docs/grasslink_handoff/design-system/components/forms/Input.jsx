import React from 'react';

export function Input({
  label, hint, error, iconLeft, size = 'md', disabled = false, id, style, ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  const autoId = React.useId();
  const inputId = id || autoId;
  const pad = size === 'sm' ? '8px 12px' : size === 'lg' ? '14px 16px' : '11px 14px';
  const fs = size === 'sm' ? 'var(--text-sm)' : size === 'lg' ? 'var(--text-lg)' : 'var(--text-md)';
  const borderColor = error ? 'var(--danger)' : focus ? 'var(--primary)' : 'var(--border-default)';

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '6px', ...style }}>
      {label && (
        <label htmlFor={inputId} style={{
          fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)',
          fontWeight: 'var(--weight-medium)', color: 'var(--text-body)',
        }}>{label}</label>
      )}
      <div style={{
        display: 'flex', alignItems: 'center', gap: '8px',
        background: disabled ? 'var(--surface-inset)' : 'var(--surface-card)',
        border: `1.5px solid ${borderColor}`, borderRadius: 'var(--radius-md)',
        padding: pad, transition: 'border-color var(--dur-fast) var(--ease-out), box-shadow var(--dur-fast) var(--ease-out)',
        boxShadow: focus && !error ? 'var(--shadow-focus)' : 'none',
      }}>
        {iconLeft && <span style={{ display: 'flex', color: 'var(--text-subtle)' }}>{iconLeft}</span>}
        <input
          id={inputId} disabled={disabled}
          onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
          style={{
            flex: 1, border: 'none', outline: 'none', background: 'transparent',
            fontFamily: 'var(--font-sans)', fontSize: fs, color: 'var(--text-strong)',
            minWidth: 0,
          }}
          {...rest}
        />
      </div>
      {(hint || error) && (
        <span style={{
          fontFamily: 'var(--font-sans)', fontSize: 'var(--text-xs)',
          color: error ? 'var(--danger)' : 'var(--text-subtle)',
        }}>{error || hint}</span>
      )}
    </div>
  );
}
