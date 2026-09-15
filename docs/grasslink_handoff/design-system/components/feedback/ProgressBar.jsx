import React from 'react';

export function ProgressBar({ value = 0, max = 100, tone = 'primary', label, showValue = false, size = 'md', style, ...rest }) {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  const tones = { primary: 'var(--primary)', accent: 'var(--accent)', success: 'var(--success)', warning: 'var(--warning)' };
  const h = size === 'sm' ? 6 : size === 'lg' ? 14 : 10;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, ...style }} {...rest}>
      {(label || showValue) && (
        <div style={{ display: 'flex', justifyContent: 'space-between', fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', color: 'var(--text-muted)' }}>
          <span>{label}</span>{showValue && <span style={{ fontWeight: 'var(--weight-semibold)', color: 'var(--text-body)' }}>{Math.round(pct)}%</span>}
        </div>
      )}
      <div style={{ height: h, background: 'var(--surface-inset)', borderRadius: 'var(--radius-pill)', overflow: 'hidden' }}>
        <div style={{
          width: `${pct}%`, height: '100%', background: tones[tone] || tones.primary,
          borderRadius: 'var(--radius-pill)', transition: 'width var(--dur-slow) var(--ease-out)',
        }} />
      </div>
    </div>
  );
}
