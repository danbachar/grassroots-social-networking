import * as React from 'react';

export interface RadioProps extends Omit<React.InputHTMLAttributes<HTMLInputElement>, 'type'> {
  label?: React.ReactNode;
  checked?: boolean;
  defaultChecked?: boolean;
  name?: string;
  value?: string;
  onChange?: (e: React.ChangeEvent<HTMLInputElement>) => void;
  style?: React.CSSProperties;
}

/** Radio button with a spring-in moss dot. Group with a shared `name`. */
export function Radio(props: RadioProps): JSX.Element;
