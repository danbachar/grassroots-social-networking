import * as React from 'react';

export interface TagProps extends React.HTMLAttributes<HTMLSpanElement> {
  children?: React.ReactNode;
  icon?: React.ReactNode;
  /** Show a remove (×) button and handle its click. */
  onRemove?: (e: React.MouseEvent<HTMLButtonElement>) => void;
  style?: React.CSSProperties;
}

/** Outlined, removable chip for topics, channels, and filters. */
export function Tag(props: TagProps): JSX.Element;
