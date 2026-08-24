import React from 'react';

export function Select({ label, hint, error, options = [], disabled = false, id, style, ...rest }) {
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
      <div style={{ position: 'relative', display: 'flex' }}>
        <select
          id={inputId} disabled={disabled}
          onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
          style={{
            appearance: 'none', width: '100%', cursor: disabled ? 'not-allowed' : 'pointer',
            fontFamily: 'var(--font-sans)', fontSize: 'var(--text-md)', color: 'var(--text-strong)',
            background: disabled ? 'var(--surface-inset)' : 'var(--surface-card)',
            border: `1.5px solid ${borderColor}`, borderRadius: 'var(--radius-md)',
            padding: '11px 40px 11px 14px', outline: 'none',
            boxShadow: focus && !error ? 'var(--shadow-focus)' : 'none',
            transition: 'border-color var(--dur-fast) var(--ease-out), box-shadow var(--dur-fast) var(--ease-out)',
          }}
          {...rest}
        >
          {options.map((o) => {
            const val = typeof o === 'string' ? o : o.value;
            const lbl = typeof o === 'string' ? o : o.label;
            return <option key={val} value={val}>{lbl}</option>;
          })}
        </select>
        <span style={{
          position: 'absolute', right: 14, top: '50%', transform: 'translateY(-50%)',
          pointerEvents: 'none', color: 'var(--text-subtle)', fontSize: 12,
        }}>▾</span>
      </div>
      {(hint || error) && (
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-xs)', color: error ? 'var(--danger)' : 'var(--text-subtle)' }}>{error || hint}</span>
      )}
    </div>
  );
}
