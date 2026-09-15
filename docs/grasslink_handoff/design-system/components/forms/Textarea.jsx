import React from 'react';

export function Textarea({ label, hint, error, rows = 4, disabled = false, id, style, ...rest }) {
  const [focus, setFocus] = React.useState(false);
  const autoId = React.useId();
  const inputId = id || autoId;
  const borderColor = error ? 'var(--danger)' : focus ? 'var(--primary)' : 'var(--border-default)';
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '6px', ...style }}>
      {label && (
        <label htmlFor={inputId} style={{
          fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)',
          fontWeight: 'var(--weight-medium)', color: 'var(--text-body)',
        }}>{label}</label>
      )}
      <textarea
        id={inputId} rows={rows} disabled={disabled}
        onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
        style={{
          fontFamily: 'var(--font-sans)', fontSize: 'var(--text-md)', color: 'var(--text-strong)',
          background: disabled ? 'var(--surface-inset)' : 'var(--surface-card)',
          border: `1.5px solid ${borderColor}`, borderRadius: 'var(--radius-md)',
          padding: '11px 14px', resize: 'vertical', outline: 'none',
          boxShadow: focus && !error ? 'var(--shadow-focus)' : 'none',
          transition: 'border-color var(--dur-fast) var(--ease-out), box-shadow var(--dur-fast) var(--ease-out)',
          lineHeight: 'var(--leading-normal)',
        }}
        {...rest}
      />
      {(hint || error) && (
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-xs)', color: error ? 'var(--danger)' : 'var(--text-subtle)' }}>{error || hint}</span>
      )}
    </div>
  );
}
