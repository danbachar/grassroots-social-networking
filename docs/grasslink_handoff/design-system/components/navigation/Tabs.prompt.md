One-line: Pill segmented control for switching views; supports icons and count badges.

```jsx
<Tabs tabs={[{value:'near',label:'Nearby',badge:4},{value:'all',label:'All threads'}]} defaultValue="near" onChange={setView} />
```
Tabs can be plain strings or `{value,label,icon,badge}`.
