// grasslink mobile app — screen recreations composed from the design-system components.
// Exports all screens + helpers to window for index.html to orchestrate.
const DS = window.GrasslinkDesignSystem_e1de82;
const { Button, IconButton, Input, Avatar, Badge, Tag, SignalMeter, Card, Tabs, Switch, ProgressBar } = DS;

// Lucide icon helper
function Icon({ n, size = 20, color, style }) {
  const ref = React.useRef();
  React.useEffect(() => {
    if (window.lucide && ref.current) {
      ref.current.innerHTML = '';
      const el = document.createElement('i');
      el.setAttribute('data-lucide', n);
      ref.current.appendChild(el);
      window.lucide.createIcons({ attrs: { width: size, height: size, stroke: color || 'currentColor' } });
    }
  });
  return <span ref={ref} style={{ display: 'inline-flex', ...style }} />;
}

const H = { fontFamily: 'var(--font-display)', fontWeight: 800, letterSpacing: '-0.02em', color: 'var(--text-strong)' };
const now = 'now';

// ---- Status bar ----
function StatusBar({ dark }) {
  const c = dark ? 'rgba(255,255,255,.95)' : 'var(--text-strong)';
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 22px 4px', fontFamily: 'var(--font-sans)', fontSize: 14, fontWeight: 700, color: c }}>
      <span>9:41</span>
      <span style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
        <Icon n="signal" size={16} color={c} /><Icon n="wifi" size={16} color={c} /><Icon n="battery-full" size={18} color={c} />
      </span>
    </div>
  );
}

// ---- Bottom nav ----
function BottomNav({ tab, onTab }) {
  const items = [['threads', 'messages-square', 'Threads'], ['mesh', 'radio-tower', 'Mesh'], ['compose', 'plus', ''], ['people', 'users-round', 'Peers'], ['me', 'user-round', 'You']];
  return (
    <div style={{ display: 'flex', justifyContent: 'space-around', alignItems: 'center', padding: '10px 8px 22px', borderTop: '1px solid var(--border-subtle)', background: 'var(--surface-card)' }}>
      {items.map(([id, ic, lbl]) => {
        if (id === 'compose') return (
          <button key={id} onClick={() => onTab('compose')} style={{ width: 52, height: 52, borderRadius: 'var(--radius-lg)', border: 'none', background: 'var(--primary)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'var(--shadow-md)', cursor: 'pointer' }}>
            <Icon n={ic} size={26} color="#fff" />
          </button>
        );
        const on = tab === id;
        return (
          <button key={id} onClick={() => onTab(id)} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, border: 'none', background: 'transparent', cursor: 'pointer', color: on ? 'var(--primary)' : 'var(--text-subtle)', minWidth: 56 }}>
            <Icon n={ic} size={22} color={on ? 'var(--primary)' : 'var(--text-subtle)'} />
            <span style={{ fontFamily: 'var(--font-sans)', fontSize: 11, fontWeight: on ? 700 : 500 }}>{lbl}</span>
          </button>
        );
      })}
    </div>
  );
}

// ---- Login / onboarding ----
function LoginScreen({ onJoin }) {
  const [handle, setHandle] = React.useState('');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: 'var(--moss-500)' }}>
      <StatusBar dark />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', padding: '0 28px', color: '#fff' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 28 }}>
          <span style={{ width: 20, height: 20, borderRadius: '50%', background: 'var(--terra-400)', boxShadow: '0 0 0 6px rgba(210,112,63,.3)' }} />
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 34, fontWeight: 800, letterSpacing: '-0.03em' }}>grass<span style={{ color: 'var(--moss-100)' }}>link</span></span>
        </div>
        <h1 style={{ ...H, color: '#fff', fontSize: 40, lineHeight: 1.05, margin: '0 0 14px' }}>A message never travels alone.</h1>
        <p style={{ fontFamily: 'var(--font-sans)', fontSize: 17, lineHeight: 1.55, color: 'var(--moss-100)', margin: '0 0 32px' }}>Join the mesh. Your neighbours carry your words to the wider world — no towers, no gatekeepers.</p>
        <div style={{ background: 'var(--surface-card)', borderRadius: 'var(--radius-xl)', padding: 20, boxShadow: 'var(--shadow-lg)' }}>
          <Input label="Choose a handle" placeholder="willow" iconLeft={<Icon n="at-sign" size={18} />} value={handle} onChange={(e) => setHandle(e.target.value)} />
          <div style={{ height: 14 }} />
          <Button variant="primary" fullWidth size="lg" iconRight={<Icon n="arrow-right" size={20} color="#fff" />} onClick={onJoin}>Join the mesh</Button>
        </div>
      </div>
    </div>
  );
}

// ---- Threads list ----
const THREADS = [
  { id: 't1', name: 'Market Square', last: 'Rafi: stalls open till 8 tonight', time: '2m', hops: 2, unread: 3, kind: 'channel', sig: 4 },
  { id: 't2', name: 'Flood watch — Riverside', last: 'You: water down 10cm since noon', time: '18m', hops: 4, unread: 0, kind: 'channel', sig: 3 },
  { id: 't3', name: 'Willow Adeyemi', last: 'Passed your note along 🌿', time: '1h', hops: 1, unread: 0, kind: 'dm', sig: 4, status: 'online' },
  { id: 't4', name: 'Ridge Line relays', last: 'Mara: lending my link overnight', time: '3h', hops: 6, unread: 0, kind: 'channel', sig: 2 },
  { id: 't5', name: 'Okoro family', last: 'Delivered via 3 peers', time: 'Yst', hops: 3, unread: 0, kind: 'dm', sig: 3, status: 'relaying' },
];

function ThreadsScreen({ onOpen }) {
  const [tab, setTab] = React.useState('near');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: 'var(--bg-page)' }}>
      <StatusBar />
      <div style={{ padding: '6px 20px 12px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
          <h1 style={{ ...H, fontSize: 28, margin: 0 }}>Threads</h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 6, background: 'var(--success-soft)', padding: '5px 10px', borderRadius: 'var(--radius-pill)' }}>
              <SignalMeter strength={4} size="sm" /><span style={{ fontFamily: 'var(--font-sans)', fontSize: 12, fontWeight: 700, color: 'var(--moss-700)' }}>Strong mesh</span>
            </span>
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--surface-card)', border: '1px solid var(--border-default)', borderRadius: 'var(--radius-md)', padding: '10px 12px' }}>
          <Icon n="search" size={18} color="var(--text-subtle)" />
          <span style={{ fontFamily: 'var(--font-sans)', fontSize: 15, color: 'var(--text-subtle)' }}>Search threads & peers</span>
        </div>
      </div>
      <div style={{ padding: '0 20px 12px' }}>
        <Tabs value={tab} onChange={setTab} tabs={[{ value: 'near', label: 'Nearby', badge: 3 }, { value: 'all', label: 'All' }, { value: 'me', label: 'Relaying' }]} />
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0 12px' }}>
        {THREADS.map((t) => (
          <button key={t.id} onClick={() => onOpen(t)} style={{ width: '100%', textAlign: 'left', border: 'none', background: 'transparent', cursor: 'pointer', display: 'flex', gap: 12, alignItems: 'center', padding: '12px 8px', borderRadius: 'var(--radius-lg)' }}>
            {t.kind === 'dm'
              ? <Avatar name={t.name} status={t.status} size="lg" />
              : <span style={{ width: 48, height: 48, borderRadius: 'var(--radius-md)', background: 'var(--primary-soft)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}><Icon n="hash" size={22} color="var(--primary-on-soft)" /></span>}
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 8 }}>
                <span style={{ fontFamily: 'var(--font-sans)', fontSize: 16, fontWeight: 700, color: 'var(--text-strong)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.name}</span>
                <span style={{ fontFamily: 'var(--font-sans)', fontSize: 12, color: 'var(--text-subtle)', flexShrink: 0 }}>{t.time}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, marginTop: 2 }}>
                <span style={{ fontFamily: 'var(--font-sans)', fontSize: 14, color: 'var(--text-muted)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.last}</span>
                {t.unread > 0
                  ? <span style={{ background: 'var(--primary)', color: '#fff', fontSize: 11, fontWeight: 700, minWidth: 20, height: 20, borderRadius: 'var(--radius-pill)', display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '0 6px', flexShrink: 0 }}>{t.unread}</span>
                  : <span style={{ display: 'flex', gap: 4, alignItems: 'center', flexShrink: 0, color: 'var(--text-subtle)' }}><Icon n="git-branch" size={13} color="var(--text-subtle)" /><span style={{ fontFamily: 'var(--font-mono)', fontSize: 11 }}>{t.hops}</span></span>}
              </div>
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}

// ---- Conversation ----
const MSGS = [
  { id: 1, me: false, who: 'Rafi Okoro', text: 'Stalls are open till 8 tonight — plenty of bread left.', time: '7:02', hops: 2 },
  { id: 2, me: false, who: 'Willow', text: 'Passing this to the Ridge Line folks 🌿', time: '7:04', hops: 1 },
  { id: 3, me: true, text: 'Thank you both. On my way now.', time: '7:06', relayed: true, hops: 3 },
  { id: 4, me: false, who: 'Rafi Okoro', text: 'Saved you a loaf. Ask for me at the corner stall.', time: '7:09', hops: 2 },
];

function ConversationScreen({ thread, onBack }) {
  const t = thread || THREADS[0];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: 'var(--bg-page)' }}>
      <StatusBar />
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '4px 12px 12px', borderBottom: '1px solid var(--border-subtle)' }}>
        <IconButton label="Back" variant="ghost" onClick={onBack}><Icon n="chevron-left" size={22} /></IconButton>
        <span style={{ width: 38, height: 38, borderRadius: 'var(--radius-md)', background: 'var(--primary-soft)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon n="hash" size={18} color="var(--primary-on-soft)" /></span>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontFamily: 'var(--font-sans)', fontSize: 16, fontWeight: 700, color: 'var(--text-strong)' }}>{t.name}</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}><SignalMeter strength={t.sig || 3} size="sm" /><span style={{ fontFamily: 'var(--font-sans)', fontSize: 12, color: 'var(--text-muted)' }}>{t.hops} hops · 12 peers</span></div>
        </div>
        <IconButton label="Info" variant="ghost"><Icon n="info" size={20} /></IconButton>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '16px 16px 8px', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <div style={{ alignSelf: 'center', display: 'flex', alignItems: 'center', gap: 6, background: 'var(--surface-inset)', padding: '4px 12px', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-sans)', fontSize: 12, color: 'var(--text-muted)' }}>
          <Icon n="route" size={13} color="var(--text-muted)" /> Carried through the neighbourhood mesh
        </div>
        {MSGS.map((m) => (
          <div key={m.id} style={{ display: 'flex', flexDirection: 'column', alignItems: m.me ? 'flex-end' : 'flex-start' }}>
            {!m.me && <span style={{ fontFamily: 'var(--font-sans)', fontSize: 12, fontWeight: 600, color: 'var(--text-subtle)', margin: '0 0 3px 12px' }}>{m.who}</span>}
            <div style={{ maxWidth: '78%', padding: '10px 14px', borderRadius: m.me ? '18px 18px 4px 18px' : '18px 18px 18px 4px', background: m.me ? 'var(--primary)' : 'var(--surface-card)', color: m.me ? '#fff' : 'var(--text-body)', border: m.me ? 'none' : '1px solid var(--border-subtle)', boxShadow: 'var(--shadow-xs)', fontFamily: 'var(--font-sans)', fontSize: 15, lineHeight: 1.45 }}>{m.text}</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 5, margin: '4px 6px 0' }}>
              <span style={{ fontFamily: 'var(--font-sans)', fontSize: 11, color: 'var(--text-subtle)' }}>{m.time}</span>
              {m.me && m.relayed && <span style={{ display: 'flex', alignItems: 'center', gap: 3, color: 'var(--success)' }}><Icon n="check-check" size={13} color="var(--success)" /><span style={{ fontFamily: 'var(--font-mono)', fontSize: 10 }}>via {m.hops}</span></span>}
            </div>
          </div>
        ))}
      </div>
      <Composer />
    </div>
  );
}

function Composer() {
  const [v, setV] = React.useState('');
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 12px 22px', borderTop: '1px solid var(--border-subtle)', background: 'var(--surface-card)' }}>
      <IconButton label="Attach" variant="ghost"><Icon n="plus" size={22} /></IconButton>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', background: 'var(--surface-inset)', borderRadius: 'var(--radius-pill)', padding: '4px 6px 4px 16px' }}>
        <input value={v} onChange={(e) => setV(e.target.value)} placeholder="Message the mesh…" style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--font-sans)', fontSize: 15, color: 'var(--text-strong)' }} />
        <IconButton label="Send" variant="solid" size="sm"><Icon n="arrow-up" size={18} color="#fff" /></IconButton>
      </div>
    </div>
  );
}

// ---- Mesh / relay status ----
function MeshScreen() {
  const [relay, setRelay] = React.useState(true);
  const peers = [
    { name: 'Willow Adeyemi', via: 'direct', sig: 4, status: 'online' },
    { name: 'Mara Vidal', via: '2 hops', sig: 3, status: 'relaying' },
    { name: 'Ridge Line node', via: '1 hop', sig: 2, status: 'relaying' },
    { name: 'Okoro family', via: '3 hops', sig: 3, status: 'offline' },
  ];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: 'var(--bg-page)' }}>
      <StatusBar />
      <div style={{ padding: '6px 20px 8px' }}><h1 style={{ ...H, fontSize: 28, margin: 0 }}>Your mesh</h1></div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '4px 16px 16px', display: 'flex', flexDirection: 'column', gap: 14 }}>
        <div style={{ background: 'var(--moss-500)', borderRadius: 'var(--radius-xl)', padding: 20, color: '#fff' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div>
              <div style={{ fontFamily: 'var(--font-sans)', fontSize: 13, color: 'var(--moss-100)', fontWeight: 600 }}>YOU'RE RELAYING FOR</div>
              <div style={{ fontFamily: 'var(--font-display)', fontSize: 44, fontWeight: 800, lineHeight: 1 }}>4 peers</div>
            </div>
            <SignalMeter strength={4} size="lg" />
          </div>
          <div style={{ marginTop: 16, display: 'flex', alignItems: 'center', justifyContent: 'space-between', background: 'rgba(255,255,255,.12)', borderRadius: 'var(--radius-md)', padding: '10px 14px' }}>
            <span style={{ fontFamily: 'var(--font-sans)', fontSize: 15, fontWeight: 600 }}>Lend my link</span>
            <Switch checked={relay} onChange={(e) => setRelay(e.target.checked)} />
          </div>
        </div>
        <Card padding="md">
          <div style={{ fontFamily: 'var(--font-sans)', fontSize: 13, fontWeight: 700, color: 'var(--text-muted)', marginBottom: 6 }}>MESSAGES CARRIED TODAY</div>
          <ProgressBar value={128} max={200} label="128 of 200 relay credits used" showValue />
        </Card>
        <div>
          <div style={{ fontFamily: 'var(--font-sans)', fontSize: 13, fontWeight: 700, color: 'var(--text-muted)', margin: '4px 6px 8px' }}>PEERS NEAR YOU</div>
          <Card padding="none">
            {peers.map((p, i) => (
              <div key={p.name} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 16px', borderTop: i ? '1px solid var(--border-subtle)' : 'none' }}>
                <Avatar name={p.name} status={p.status} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontFamily: 'var(--font-sans)', fontSize: 15, fontWeight: 600, color: 'var(--text-strong)' }}>{p.name}</div>
                  <div style={{ fontFamily: 'var(--font-sans)', fontSize: 13, color: 'var(--text-muted)' }}>{p.via}</div>
                </div>
                <SignalMeter strength={p.sig} size="sm" />
              </div>
            ))}
          </Card>
        </div>
      </div>
    </div>
  );
}

// ---- Compose ----
function ComposeScreen({ onClose, onSend }) {
  const [msg, setMsg] = React.useState('');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', background: 'var(--bg-page)' }}>
      <StatusBar />
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 12px 12px' }}>
        <IconButton label="Close" variant="ghost" onClick={onClose}><Icon n="x" size={22} /></IconButton>
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: 16, fontWeight: 700, color: 'var(--text-strong)' }}>New message</span>
        <Button size="sm" iconRight={<Icon n="send" size={16} color="#fff" />} onClick={onSend}>Relay</Button>
      </div>
      <div style={{ flex: 1, padding: '4px 16px', display: 'flex', flexDirection: 'column', gap: 16 }}>
        <div>
          <div style={{ fontFamily: 'var(--font-sans)', fontSize: 13, fontWeight: 700, color: 'var(--text-muted)', marginBottom: 8 }}>SEND TO</div>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <Tag icon={<Icon n="hash" size={13} />}>market-square</Tag>
            <Tag onRemove={() => {}}>Willow</Tag>
            <button style={{ display: 'inline-flex', alignItems: 'center', gap: 4, border: '1px dashed var(--border-strong)', background: 'transparent', borderRadius: 'var(--radius-pill)', padding: '5px 12px', fontFamily: 'var(--font-sans)', fontSize: 14, color: 'var(--text-muted)', cursor: 'pointer' }}><Icon n="plus" size={14} /> Add peer</button>
          </div>
        </div>
        <textarea value={msg} onChange={(e) => setMsg(e.target.value)} placeholder="What should the neighbourhood know?" rows={6} style={{ fontFamily: 'var(--font-sans)', fontSize: 17, lineHeight: 1.5, color: 'var(--text-strong)', border: 'none', outline: 'none', background: 'transparent', resize: 'none' }} />
      </div>
      <div style={{ padding: '12px 16px 22px', borderTop: '1px solid var(--border-subtle)', display: 'flex', alignItems: 'center', gap: 10, background: 'var(--surface-card)' }}>
        <Icon n="route" size={18} color="var(--text-subtle)" />
        <span style={{ fontFamily: 'var(--font-sans)', fontSize: 13, color: 'var(--text-muted)', flex: 1 }}>Will hop through ~3 peers to reach everyone</span>
        <Badge tone="success">Mesh ready</Badge>
      </div>
    </div>
  );
}

Object.assign(window, { GLIcon: Icon, StatusBar, BottomNav, LoginScreen, ThreadsScreen, ConversationScreen, MeshScreen, ComposeScreen, THREADS });
