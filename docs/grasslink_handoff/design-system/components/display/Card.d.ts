import * as React from 'react';

export interface CardProps extends React.HTMLAttributes<HTMLDivElement> {
  children?: React.ReactNode;
  /** @default "sm" */
  elevation?: 'flat' | 'sm' | 'md' | 'lg';
  /** @default "md" */
  padding?: 'none' | 'sm' | 'md' | 'lg';
  /** Adds hover lift + pointer cursor. */
  interactive?: boolean;
  style?: React.CSSProperties;
}

/**
 * Rounded content surface — the brand's fundamental container.
 * @startingPoint section="Display" subtitle="Content surfaces & elevations" viewport="700x260"
 */
export function Card(props: CardProps): JSX.Element;
