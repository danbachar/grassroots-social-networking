import * as React from 'react';

export interface ButtonProps {
  children?: React.ReactNode;
  /** Visual style. @default "primary" */
  variant?: 'primary' | 'secondary' | 'soft' | 'outline' | 'ghost';
  /** @default "md" */
  size?: 'sm' | 'md' | 'lg';
  disabled?: boolean;
  fullWidth?: boolean;
  iconLeft?: React.ReactNode;
  iconRight?: React.ReactNode;
  type?: 'button' | 'submit' | 'reset';
  onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void;
  style?: React.CSSProperties;
}

/**
 * Primary call-to-action button.
 * @startingPoint section="Forms" subtitle="Buttons in every variant & size" viewport="700x180"
 */
export function Button(props: ButtonProps): JSX.Element;
