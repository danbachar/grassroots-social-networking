import * as React from 'react';

export interface InputProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, 'size'> {
  label?: string;
  hint?: string;
  error?: string;
  iconLeft?: React.ReactNode;
  /** @default "md" */
  size?: 'sm' | 'md' | 'lg';
  disabled?: boolean;
  style?: React.CSSProperties;
}

/** Text field with optional label, leading icon, hint and error states. */
export function Input(props: InputProps): JSX.Element;
