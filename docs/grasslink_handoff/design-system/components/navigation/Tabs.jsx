import React from 'react';

export function Tabs({ tabs = [], value, defaultValue, onChange, style, ...rest }) {
  const first = defaultValue ?? (tabs[0] && (tabs[0].value ?? tabs[0]));
  const [internal, setInternal] = React.useState(first);
  const isControlled = value !== undefined;
  const active = isControlled ? value : internal;
  const select = (v) => { if (!isControlled) setInternal(v); onChange && onChange(v); };
  return (
    <div role="tablist" style={{
      display: 'inline-flex', gap: 4, padding: 4,
      background: 'var(--surface-inset)', borderRadius: 'var(--radius-pill)', ...style,
    }} {...rest}>
      {tabs.map((t) => {
        const val = t.value ?? t;
        const lbl = t.label ?? t;
        const on = val === active;
        return (
          <button key={val} role="tab" aria-selected={on} onClick={() => select(val)} style={{
            display: 'inline-flex', alignItems: 'center', gap: 6,
            fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', fontWeight: 'var(--weight-semibold)',
            padding: '7px 16px', borderRadius: 'var(--radius-pill)', border: 'none', cursor: 'pointer',
            background: on ? 'var(--surface-card)' : 'transparent',
            color: on ? 'var(--text-strong)' : 'var(--text-muted)',
            boxShadow: on ? 'var(--shadow-sm)' : 'none',
            transition: 'background var(--dur-normal) var(--ease-out), color var(--dur-normal) var(--ease-out)',
          }}>
            {t.icon && <span style={{ display: 'flex' }}>{t.icon}</span>}{lbl}
            {t.badge != null && (
              <span style={{ background: on ? 'var(--primary-soft)' : 'var(--clay-200)', color: on ? 'var(--primary-on-soft)' : 'var(--text-muted)', fontSize: 'var(--text-2xs)', fontWeight: 'var(--weight-bold)', padding: '1px 7px', borderRadius: 'var(--radius-pill)' }}>{t.badge}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}
