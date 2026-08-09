# grasslink app — UI kit

Interactive recreation of the grasslink mobile app: a peer-to-peer mesh messaging client where neighbours relay each other's messages to the wider internet.

## Screens
- **LoginScreen** — moss full-bleed onboarding; pick a handle, "Join the mesh".
- **ThreadsScreen** — channels + DMs list, mesh-strength header, search, Tabs (Nearby / All / Relaying).
- **ConversationScreen** — message thread with per-message hop counts, relay-path banner, composer.
- **MeshScreen** — your relay status ("relaying for N peers"), lend-my-link toggle, relay-credit progress, nearby peers with SignalMeter.
- **ComposeScreen** — new message with recipient Tags and a mesh-route hint.

## Composition
All screens are built from the design-system components (`window.GrasslinkDesignSystem_*`): Button, IconButton, Input, Avatar, Badge, Tag, SignalMeter, Card, Tabs, Switch, ProgressBar. Icons are Lucide (CDN). `index.html` wires an interactive flow: login → threads → open a thread / compose / mesh tab.

Files: `index.html` (shell + navigation), `screens.jsx` (all screens, exported to window).
