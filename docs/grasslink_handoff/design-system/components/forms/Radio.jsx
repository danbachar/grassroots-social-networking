import React from 'react';

export function Radio({ label, checked, defaultChecked, onChange, name, value, disabled = false, id, style, ...rest }) {
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
      <input id={inputId} type="radio" name={name} value={value} checked={on} disabled={disabled} onChange={toggle}
        style={{ position: 'absolute', opacity: 0, width: 1, height: 1 }} {...rest} />
      <span style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        width: 20, height: 20, flexShrink: 0, borderRadius: '50%',
        background: 'var(--surface-card)',
        border: `1.5px solid ${on ? 'var(--primary)' : 'var(--border-strong)'}`,
        transition: 'border-color var(--dur-fast) var(--ease-out)',
      }}>
        <span style={{
          width: 10, height: 10, borderRadius: '50%',
          background: on ? 'var(--primary)' : 'transparent',
          transform: on ? 'scale(1)' : 'scale(0)',
          transition: 'transform var(--dur-fast) var(--ease-spring)',
        }} />
      </span>
      {label}
    </label>
  );
}
