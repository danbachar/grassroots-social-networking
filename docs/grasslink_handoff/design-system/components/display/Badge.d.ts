import * as React from 'react';

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  children?: React.ReactNode;
  /** @default "neutral" */
  tone?: 'neutral' | 'primary' | 'accent' | 'success' | 'warning' | 'danger' | 'info';
  /** @default "soft" */
  variant?: 'soft' | 'solid';
  style?: React.CSSProperties;
}

/** Small pill for status and counts. */
export function Badge(props: BadgeProps): JSX.Element;
