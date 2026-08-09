import React from 'react';

const sizes = { sm: 32, md: 40, lg: 48 };

export function IconButton({
  children, label, variant = 'ghost', size = 'md', disabled = false, onClick, style, ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [active, setActive] = React.useState(false);
  const dim = sizes[size] || sizes.md;
  const palettes = {
    ghost:   { base: 'transparent', hover: 'var(--clay-100)', active: 'var(--clay-200)', color: 'var(--text-body)', border: 'transparent' },
    soft:    { base: 'var(--primary-soft)', hover: 'var(--moss-200)', active: 'var(--moss-200)', color: 'var(--primary-on-soft)', border: 'transparent' },
    solid:   { base: 'var(--primary)', hover: 'var(--primary-hover)', active: 'var(--primary-active)', color: '#fff', border: 'transparent' },
    outline: { base: 'transparent', hover: 'var(--clay-100)', active: 'var(--clay-200)', color: 'var(--text-body)', border: 'var(--border-strong)' },
  };
  const p = palettes[variant] || palettes.ghost;
  const bg = active ? p.active : hover ? p.hover : p.base;

  return (
    <button
      type="button" aria-label={label} title={label} disabled={disabled} onClick={onClick}
      onMouseEnter={() => setHover(true)} onMouseLeave={() => { setHover(false); setActive(false); }}
      onMouseDown={() => setActive(true)} onMouseUp={() => setActive(false)}
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        width: dim, height: dim, padding: 0,
        borderRadius: 'var(--radius-md)', background: bg, color: p.color,
        border: `1px solid ${p.border}`,
        cursor: disabled ? 'not-allowed' : 'pointer', opacity: disabled ? 0.5 : 1,
        transform: active && !disabled ? 'scale(0.92)' : 'scale(1)',
        transition: 'background var(--dur-fast) var(--ease-out), transform var(--dur-fast) var(--ease-out)',
        ...style,
      }}
      {...rest}
    >
      {children}
    </button>
  );
}
