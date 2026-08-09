import React from 'react';

export function Tooltip({ children, label, side = 'top', style, ...rest }) {
  const [show, setShow] = React.useState(false);
  const pos = {
    top: { bottom: '100%', left: '50%', transform: 'translateX(-50%)', marginBottom: 8 },
    bottom: { top: '100%', left: '50%', transform: 'translateX(-50%)', marginTop: 8 },
    left: { right: '100%', top: '50%', transform: 'translateY(-50%)', marginRight: 8 },
    right: { left: '100%', top: '50%', transform: 'translateY(-50%)', marginLeft: 8 },
  };
  return (
    <span
      style={{ position: 'relative', display: 'inline-flex', ...style }}
      onMouseEnter={() => setShow(true)} onMouseLeave={() => setShow(false)}
      onFocus={() => setShow(true)} onBlur={() => setShow(false)}
      {...rest}
    >
      {children}
      {show && (
        <span role="tooltip" style={{
          position: 'absolute', zIndex: 1100, whiteSpace: 'nowrap', pointerEvents: 'none',
          background: 'var(--surface-inverse)', color: 'var(--text-inverse)',
          fontFamily: 'var(--font-sans)', fontSize: 'var(--text-xs)', fontWeight: 'var(--weight-medium)',
          padding: '6px 10px', borderRadius: 'var(--radius-sm)', boxShadow: 'var(--shadow-md)',
          animation: 'gl-tip var(--dur-fast) var(--ease-out)', ...pos[side],
        }}>
          {label}
        </span>
      )}
      <style>{`@keyframes gl-tip{from{opacity:0}to{opacity:1}}`}</style>
    </span>
  );
}
