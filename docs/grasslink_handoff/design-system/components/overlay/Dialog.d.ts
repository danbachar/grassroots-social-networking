import * as React from 'react';

export interface DialogProps extends React.HTMLAttributes<HTMLDivElement> {
  open?: boolean;
  title?: string;
  children?: React.ReactNode;
  /** Footer node — typically action Buttons. */
  footer?: React.ReactNode;
  onClose?: () => void;
  /** Max width in px. @default 460 */
  width?: number;
  style?: React.CSSProperties;
}

/** Centered modal with scrim, blur, and spring entrance. */
export function Dialog(props: DialogProps): JSX.Element | null;
