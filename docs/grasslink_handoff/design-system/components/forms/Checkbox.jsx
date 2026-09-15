import React from 'react';

export function Checkbox({ label, checked, defaultChecked, onChange, disabled = false, id, style, ...rest }) {
  const autoId = React.useId();
  const inputId = id || autoId;
  const [internal, setInternal] = React.useState(!!defaultChecked);
  const isControlled = checked !== undefined;
  const on = isControlled ? checked : internal;
  const toggle = (e) => { if (!isControlled) setInternal(e.target.checked); onChange && onChange(e); };
  return (
    <label htmlFor={inputId} style={{
      display: 'inline-flex', alignItems: 'center', gap: '10px',
      cursor: disabled ? 'not-allowed' : 'pointer', opacity: disabled ? 0.5 : 1,
      fontFamily: 'var(--font-sans)', fontSize: 'var(--text-md)', color: 'var(--text-body)', ...style,
    }}>
      <input id={inputId} type="checkbox" checked={on} disabled={disabled} onChange={toggle}
        style={{ position: 'absolute', opacity: 0, width: 1, height: 1 }} {...rest} />
      <span style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        width: 20, height: 20, flexShrink: 0, borderRadius: 'var(--radius-xs)',
        background: on ? 'var(--primary)' : 'var(--surface-card)',
        border: `1.5px solid ${on ? 'var(--primary)' : 'var(--border-strong)'}`,
        transition: 'background var(--dur-fast) var(--ease-out), border-color var(--dur-fast) var(--ease-out)',
      }}>
        {on && (
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="3.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"/></svg>
        )}
      </span>
      {label}
    </label>
  );
}
