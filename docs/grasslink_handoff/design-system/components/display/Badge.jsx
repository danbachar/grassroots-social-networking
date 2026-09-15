import React from 'react';

export function Badge({ children, tone = 'neutral', variant = 'soft', style, ...rest }) {
  const tones = {
    neutral: { soft: ['var(--clay-100)', 'var(--clay-700)'], solid: ['var(--clay-600)', '#fff'] },
    primary: { soft: ['var(--primary-soft)', 'var(--primary-on-soft)'], solid: ['var(--primary)', '#fff'] },
    accent:  { soft: ['var(--accent-soft)', 'var(--accent-on-soft)'], solid: ['var(--accent)', '#fff'] },
    success: { soft: ['var(--success-soft)', 'var(--moss-700)'], solid: ['var(--success)', '#fff'] },
    warning: { soft: ['var(--warning-soft)', 'var(--clay-800)'], solid: ['var(--warning)', '#fff'] },
    danger:  { soft: ['var(--danger-soft)', 'var(--rust-500)'], solid: ['var(--danger)', '#fff'] },
    info:    { soft: ['var(--info-soft)', 'var(--sky-500)'], solid: ['var(--info)', '#fff'] },
  };
  const [bg, fg] = (tones[tone] || tones.neutral)[variant] || tones.neutral.soft;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      background: bg, color: fg,
      fontFamily: 'var(--font-sans)', fontSize: 'var(--text-xs)', fontWeight: 'var(--weight-semibold)',
      letterSpacing: 'var(--tracking-snug)', padding: '3px 9px', borderRadius: 'var(--radius-pill)',
      ...style,
    }} {...rest}>{children}</span>
  );
}
