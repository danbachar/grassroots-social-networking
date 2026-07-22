import * as React from 'react';

export interface SelectOption { value: string; label: string; }

export interface SelectProps extends Omit<React.SelectHTMLAttributes<HTMLSelectElement>, 'children'> {
  label?: string;
  hint?: string;
  error?: string;
  options?: (string | SelectOption)[];
  style?: React.CSSProperties;
}

/** Native select styled to match the form family, with a custom chevron. */
export function Select(props: SelectProps): JSX.Element;
