import * as React from 'react';

export interface ProgressBarProps extends React.HTMLAttributes<HTMLDivElement> {
  value?: number;
  max?: number;
  /** @default "primary" */
  tone?: 'primary' | 'accent' | 'success' | 'warning';
  label?: string;
  showValue?: boolean;
  /** @default "md" */
  size?: 'sm' | 'md' | 'lg';
  style?: React.CSSProperties;
}

/** Horizontal progress / capacity bar. */
export function ProgressBar(props: ProgressBarProps): JSX.Element;
