import * as React from 'react';

export interface AvatarProps extends React.HTMLAttributes<HTMLSpanElement> {
  name?: string;
  src?: string;
  /** @default "md" */
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl';
  /** Presence dot. */
  status?: 'online' | 'relaying' | 'offline';
  style?: React.CSSProperties;
}

/** Circular peer avatar; falls back to colored initials derived from the name. */
export function Avatar(props: AvatarProps): JSX.Element;
