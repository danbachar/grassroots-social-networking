One-line: Outlined chip for topics/channels/filters; pass `onRemove` to make it dismissable.

```jsx
<Tag icon={<HashIcon/>}>market-square</Tag>
<Tag onRemove={() => drop(t)}>flood-watch</Tag>
```
