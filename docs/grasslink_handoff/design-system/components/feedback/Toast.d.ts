import * as React from 'react';

export interface ToastProps extends React.HTMLAttributes<HTMLDivElement> {
  title?: string;
  message?: string;
  /** @default "neutral" */
  tone?: 'neutral' | 'primary' | 'success' | 'warning' | 'danger' | 'info';
  icon?: React.ReactNode;
  onDismiss?: () => void;
  style?: React.CSSProperties;
}

/** Transient notification card with a tone accent bar. */
export function Toast(props: ToastProps): JSX.Element;
