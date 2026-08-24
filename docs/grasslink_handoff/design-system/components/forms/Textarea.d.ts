import * as React from 'react';

export interface TextareaProps extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
  label?: string;
  hint?: string;
  error?: string;
  style?: React.CSSProperties;
}

/** Multi-line text field matching Input's styling. */
export function Textarea(props: TextareaProps): JSX.Element;
