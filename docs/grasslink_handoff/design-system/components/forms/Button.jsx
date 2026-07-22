import React from 'react';

const sizes = {
  sm: { padding: '7px 14px', fontSize: 'var(--text-sm)', gap: '6px', radius: 'var(--radius-sm)' },
  md: { padding: '10px 20px', fontSize: 'var(--text-md)', gap: '8px', radius: 'var(--radius-md)' },
  lg: { padding: '14px 26px', fontSize: 'var(--text-lg)', gap: '10px', radius: 'var(--radius-lg)' },
};

const variants = {
  primary: {
    background: 'var(--primary)', color: 'var(--text-on-primary)',
    border: '1px solid transparent',
    '--hover-bg': 'var(--primary-hover)', '--active-bg': 'var(--primary-active)',
  },
  secondary: {
    background: 'var(--accent)', color: 'var(--text-on-primary)',
    border: '1px solid transparent',
    '--hover-bg': 'var(--accent-hover)', '--active-bg': 'var(--accent-active)',
  },
  soft: {
    background: 'var(--primary-soft)', color: 'var(--primary-on-soft)',
    border: '1px solid transparent',
    '--hover-bg': 'var(--moss-200)', '--active-bg': 'var(--moss-200)',
  },
  outline: {
    background: 'transparent', color: 'var(--text-body)',
    border: '1px solid var(--border-strong)',
    '--hover-bg': 'var(--clay-100)', '--active-bg': 'var(--clay-200)',
  },
  ghost: {
    background: 'transparent', color: 'var(--text-body)',
    border: '1px solid transparent',
    '--hover-bg': 'var(--clay-100)', '--active-bg': 'var(--clay-200)',
  },
};

export function Button({
  children, variant = 'primary', size = 'md', disabled = false,
  fullWidth = false, iconLeft, iconRight, type = 'button', onClick, style, ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [active, setActive] = React.useState(false);
  const s = sizes[size] || sizes.md;
  const v = variants[variant] || variants.primary;
  const bg = active ? v['--active-bg'] : hover ? v['--hover-bg'] : v.background;

  return (
    <button
      type={type} disabled={disabled} onClick={onClick}
      onMouseEnter={() => setHover(true)} onMouseLeave={() => { setHover(false); setActive(false); }}
      onMouseDown={() => setActive(true)} onMouseUp={() => setActive(false)}
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        gap: s.gap, width: fullWidth ? '100%' : 'auto',
        fontFamily: 'var(--font-sans)', fontWeight: 'var(--weight-semibold)',
        fontSize: s.fontSize, lineHeight: 1, letterSpacing: 'var(--tracking-snug)',
        padding: s.padding, borderRadius: s.radius,
        background: bg, color: v.color, border: v.border,
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        transform: active && !disabled ? 'scale(0.97)' : 'scale(1)',
        transition: 'background var(--dur-fast) var(--ease-out), transform var(--dur-fast) var(--ease-out)',
        boxShadow: variant === 'primary' || variant === 'secondary' ? 'var(--shadow-xs)' : 'none',
        ...style,
      }}
      {...rest}
    >
      {iconLeft}{children}{iconRight}
    </button>
  );
}
