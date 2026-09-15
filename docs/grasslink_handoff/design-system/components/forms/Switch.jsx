import React from 'react';

export function Switch({ label, checked, defaultChecked, onChange, disabled = false, id, style, ...rest }) {
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
        position: 'relative', width: 44, height: 26, flexShrink: 0, borderRadius: 'var(--radius-pill)',
        background: on ? 'var(--primary)' : 'var(--clay-300)',
        transition: 'background var(--dur-normal) var(--ease-out)',
      }}>
        <span style={{
          position: 'absolute', top: 3, left: 3, width: 20, height: 20, borderRadius: '50%',
          background: '#fff', boxShadow: 'var(--shadow-sm)',
          transform: on ? 'translateX(18px)' : 'translateX(0)',
          transition: 'transform var(--dur-normal) var(--ease-spring)',
        }} />
      </span>
      {label}
    </label>
  );
}
