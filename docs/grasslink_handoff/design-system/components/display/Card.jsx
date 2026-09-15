import React from 'react';

export function Card({ children, elevation = 'sm', padding = 'md', interactive = false, style, ...rest }) {
  const [hover, setHover] = React.useState(false);
  const pads = { none: 0, sm: 'var(--space-4)', md: 'var(--space-5)', lg: 'var(--space-6)' };
  const shadows = { flat: 'none', sm: 'var(--shadow-sm)', md: 'var(--shadow-md)', lg: 'var(--shadow-lg)' };
  const base = shadows[elevation] || shadows.sm;
  return (
    <div
      onMouseEnter={() => interactive && setHover(true)}
      onMouseLeave={() => interactive && setHover(false)}
      style={{
        background: 'var(--surface-card)',
        border: '1px solid var(--border-subtle)',
        borderRadius: 'var(--radius-lg)',
        padding: pads[padding],
        boxShadow: interactive && hover ? 'var(--shadow-md)' : base,
        transform: interactive && hover ? 'translateY(-2px)' : 'none',
        transition: 'box-shadow var(--dur-normal) var(--ease-out), transform var(--dur-normal) var(--ease-out)',
        cursor: interactive ? 'pointer' : 'default',
        ...style,
      }}
      {...rest}
    >
      {children}
    </div>
  );
}
