import * as React from 'react';

export interface TooltipProps extends React.HTMLAttributes<HTMLSpanElement> {
  children?: React.ReactNode;
  label: React.ReactNode;
  /** @default "top" */
  side?: 'top' | 'bottom' | 'left' | 'right';
  style?: React.CSSProperties;
}

/** Hover/focus tooltip on an inverse (dark clay) surface. */
export function Tooltip(props: TooltipProps): JSX.Element;
