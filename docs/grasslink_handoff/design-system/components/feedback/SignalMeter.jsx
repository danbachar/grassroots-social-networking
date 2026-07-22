import React from 'react';

/** Brand-specific: peer mesh signal strength, shown as growing bars. */
export function SignalMeter({ strength = 3, bars = 4, size = 'md', showLabel = false, style, ...rest }) {
  const dims = { sm: { w: 4, gap: 2, unit: 4 }, md: { w: 5, gap: 3, unit: 5 }, lg: { w: 7, gap: 4, unit: 7 } };
  const d = dims[size] || dims.md;
  const active = Math.max(0, Math.min(bars, strength));
  const color = active === 0 ? 'var(--clay-400)' : active <= 1 ? 'var(--danger)' : active <= 2 ? 'var(--warning)' : 'var(--success)';
  const labels = ['No mesh', 'Weak', 'Fair', 'Strong', 'Excellent'];
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, ...style }} {...rest}>
      <span style={{ display: 'inline-flex', alignItems: 'flex-end', gap: d.gap, height: d.unit * bars }}>
        {Array.from({ length: bars }).map((_, i) => (
          <span key={i} style={{
            width: d.w, height: d.unit * (i + 1), borderRadius: 3,
            background: i < active ? color : 'var(--clay-200)',
            transition: 'background var(--dur-normal) var(--ease-out)',
          }} />
        ))}
      </span>
      {showLabel && (
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: 'var(--text-sm)', fontWeight: 'var(--weight-medium)', color: 'var(--text-muted)' }}>
          {labels[active]}
        </span>
      )}
    </span>
  );
}
