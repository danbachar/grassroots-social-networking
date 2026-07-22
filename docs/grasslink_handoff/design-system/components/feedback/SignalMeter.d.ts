import * as React from 'react';

export interface SignalMeterProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Active bars (0..bars). @default 3 */
  strength?: number;
  /** @default 4 */
  bars?: number;
  /** @default "md" */
  size?: 'sm' | 'md' | 'lg';
  showLabel?: boolean;
  style?: React.CSSProperties;
}

/**
 * Brand-specific: peer mesh signal strength as growing bars, colored by health.
 * Intentional addition — grasslink's defining metaphor is the strength of the peer link.
 */
export function SignalMeter(props: SignalMeterProps): JSX.Element;
