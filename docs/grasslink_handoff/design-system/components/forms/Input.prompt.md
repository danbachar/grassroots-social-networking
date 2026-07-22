One-line: Labelled text input with hint/error states and an optional leading icon.

```jsx
<Input label="Peer handle" placeholder="@willow" iconLeft={<AtSignIcon/>} />
<Input label="Relay key" error="That key is not recognised" />
```

Focus shows a terracotta focus ring. Pass `error` to switch to danger styling. Sizes `sm|md|lg`. All native input attrs pass through.
