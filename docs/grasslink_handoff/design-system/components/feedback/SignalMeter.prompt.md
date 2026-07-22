One-line: grasslink's signature meter — peer mesh signal strength as growing bars, colored red→amber→moss by health.

```jsx
<SignalMeter strength={3} showLabel />
<SignalMeter strength={1} size="sm" />
```
`strength` 0..`bars` (default 4). Color: 0 grey, 1 danger, 2 warning, 3+ success. This is the brand's core connectivity metaphor — use it wherever peer-link quality matters.
