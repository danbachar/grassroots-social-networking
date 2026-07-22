One-line: The grasslink action button — rounded, warm, soft-pressed; use for any primary or secondary action.

```jsx
<Button variant="primary" size="md" onClick={handleSend}>Relay message</Button>
<Button variant="soft" iconLeft={<PlusIcon/>}>Add peer</Button>
<Button variant="outline" size="sm">Cancel</Button>
```

Variants: `primary` (moss), `secondary` (terracotta), `soft` (tinted), `outline`, `ghost`. Sizes `sm|md|lg`. Props: `fullWidth`, `disabled`, `iconLeft`, `iconRight`. Presses gently scale down (0.97) — the brand's tactile, humane feel.
