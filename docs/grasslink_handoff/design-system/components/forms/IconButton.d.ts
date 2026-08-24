import * as React from 'react';

export interface IconButtonProps {
  /** The icon node (e.g. a Lucide SVG). */
  children?: React.ReactNode;
  /** Accessible label — required for icon-only buttons. */
  label: string;
  /** @default "ghost" */
  variant?: 'ghost' | 'soft' | 'solid' | 'outline';
  /** @default "md" */
  size?: 'sm' | 'md' | 'lg';
  disabled?: boolean;
  onClick?: (e: React.MouseEvent<HTMLButtonElement>) => void;
  style?: React.CSSProperties;
}

/** Square icon-only button with an accessible label. */
export function IconButton(props: IconButtonProps): JSX.Element;
