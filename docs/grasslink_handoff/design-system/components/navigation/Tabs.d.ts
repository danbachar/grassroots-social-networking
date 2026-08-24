import * as React from 'react';

export interface TabItem {
  value: string;
  label: React.ReactNode;
  icon?: React.ReactNode;
  badge?: React.ReactNode;
}

export interface TabsProps extends Omit<React.HTMLAttributes<HTMLDivElement>, 'onChange'> {
  tabs: (TabItem | string)[];
  value?: string;
  defaultValue?: string;
  onChange?: (value: string) => void;
  style?: React.CSSProperties;
}

/** Pill segmented tabs. Controlled or uncontrolled. */
export function Tabs(props: TabsProps): JSX.Element;
