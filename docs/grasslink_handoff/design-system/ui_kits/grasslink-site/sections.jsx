// grasslink marketing site — section recreations. Exported to window for index.html.
const DS = window.GrasslinkDesignSystem_e1de82;
const { Button, Badge, Card, SignalMeter, Tag, Avatar } = DS;

function Icon({ n, size = 20, color, style }) {
  const ref = React.useRef();
  React.useEffect(() => {
    if (window.lucide && ref.current) {
      ref.current.innerHTML = '';
      const el = document.createElement('i'); el.setAttribute('data-lucide', n); ref.current.appendChild(el);
      window.lucide.createIcons({ attrs: { width: size, height: size, stroke: color || 'currentColor' } });
    }
  });
  return <span ref={ref} style={{ display: 'inline-flex', ...style }} />;
}
const wrap = { maxWidth: 1120, margin: '0 auto', padding: '0 32px' };
const H = { fontFamily: 'var(--font-display)', fontWeight: 800, letterSpacing: '-0.03em', color: 'var(--text-strong)', margin: 0 };

function Nav() {
  const links = ['How it works', 'Community', 'Coverage', 'Support'];
  return (
    <header style={{ position: 'sticky', top: 0, zIndex: 10, background: 'rgba(251,246,238,.85)', backdropFilter: 'blur(10px)', borderBottom: '1px solid var(--border-subtle)' }}>
      <div style={{ ...wrap, display: 'flex', alignItems: 'center', justifyContent: 'space-between', height: 70 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ width: 16, height: 16, borderRadius: '50%', background: 'var(--terra-400)', boxShadow: '0 0 0 5px rgba(210,112,63,.25)' }} />
          <span style={{ fontFamily: 'var(--font-display)', fontSize: 24, fontWeight: 800, letterSpacing: '-0.03em', color: 'var(--text-strong)' }}>grass<span style={{ color: 'var(--primary)' }}>link</span></span>
        </div>
        <nav style={{ display: 'flex', gap: 32 }}>
          {links.map((l) => <a key={l} href="#" style={{ fontFamily: 'var(--font-sans)', fontSize: 15, fontWeight: 500, color: 'var(--text-body)', textDecoration: 'none' }}>{l}</a>)}
        </nav>
        <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
          <Button variant="ghost" size="sm">Sign in</Button>
          <Button variant="primary" size="sm">Join the mesh</Button>
        </div>
      </div>
    </header>
  );
}

function Hero() {
  return (
    <section style={{ ...wrap, paddingTop: 72, paddingBottom: 72, display: 'grid', gridTemplateColumns: '1.05fr 0.95fr', gap: 56, alignItems: 'center' }}>
      <div>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8, background: 'var(--primary-soft)', color: 'var(--primary-on-soft)', padding: '6px 14px', borderRadius: 'var(--radius-pill)', fontFamily: 'var(--font-sans)', fontSize: 14, fontWeight: 700, marginBottom: 22 }}>
          <Icon n="sprout" size={16} color="var(--primary-on-soft)" /> Grassroots connectivity
        </span>
        <h1 style={{ ...H, fontSize: 60, lineHeight: 1.02 }}>The internet, passed hand&nbsp;to&nbsp;hand.</h1>
        <p style={{ fontFamily: 'var(--font-sans)', fontSize: 20, lineHeight: 1.55, color: 'var(--text-muted)', margin: '22px 0 32px', maxWidth: 480 }}>grasslink is a people-powered mesh. Your neighbours relay your messages and lend their connection — so everyone stays linked, even where the towers don't reach.</p>
        <div style={{ display: 'flex', gap: 14, alignItems: 'center' }}>
          <Button variant="primary" size="lg" iconRight={<Icon n="arrow-right" size={20} color="#fff" />}>Join the mesh</Button>
          <Button variant="outline" size="lg" iconLeft={<Icon n="play" size={18} />}>See how it works</Button>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginTop: 32 }}>
          <div style={{ display: 'flex' }}>
            {['Willow A', 'Rafi O', 'Mara V', 'Sam K'].map((n, i) => <span key={n} style={{ marginLeft: i ? -10 : 0, border: '2px solid var(--bg-page)', borderRadius: '50%' }}><Avatar name={n} size="sm" /></span>)}
          </div>
          <span style={{ fontFamily: 'var(--font-sans)', fontSize: 14, color: 'var(--text-muted)' }}><b style={{ color: 'var(--text-strong)' }}>48,000+</b> peers relaying today</span>
        </div>
      </div>
      <div style={{ position: 'relative' }}>
        <div style={{ background: 'var(--moss-500)', borderRadius: 'var(--radius-2xl)', padding: 28, boxShadow: 'var(--shadow-xl)', color: '#fff' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
            <span style={{ fontFamily: 'var(--font-sans)', fontWeight: 700, fontSize: 15 }}>Riverside mesh</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'rgba(255,255,255,.15)', padding: '4px 10px', borderRadius: 'var(--radius-pill)' }}><SignalMeter strength={4} size="sm" /><span style={{ fontSize: 12, fontWeight: 700 }}>Strong</span></span>
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            {[['Willow', 'Passed your note to the Ridge Line 🌿', 'direct'], ['Rafi', 'Stalls open till 8 tonight', '2 hops'], ['Mara', 'Lending my link overnight', '1 hop']].map(([who, text, via]) => (
              <div key={who} style={{ background: 'rgba(255,255,255,.12)', borderRadius: 'var(--radius-lg)', padding: '12px 14px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 3 }}><span style={{ fontFamily: 'var(--font-sans)', fontSize: 13, fontWeight: 700, color: 'var(--moss-100)' }}>{who}</span><span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--moss-200)' }}>{via}</span></div>
                <div style={{ fontFamily: 'var(--font-sans)', fontSize: 15 }}>{text}</div>
              </div>
            ))}
          </div>
        </div>
        <div style={{ position: 'absolute', bottom: -20, left: -20, background: 'var(--surface-card)', borderRadius: 'var(--radius-lg)', padding: '12px 16px', boxShadow: 'var(--shadow-lg)', display: 'flex', alignItems: 'center', gap: 10 }}>
          <span style={{ width: 40, height: 40, borderRadius: 'var(--radius-md)', background: 'var(--terra-100)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon n="route" size={20} color="var(--terra-600)" /></span>
          <div><div style={{ fontFamily: 'var(--font-display)', fontWeight: 800, fontSize: 18, color: 'var(--text-strong)' }}>3 hops</div><div style={{ fontFamily: 'var(--font-sans)', fontSize: 12, color: 'var(--text-muted)' }}>to the open internet</div></div>
        </div>
      </div>
    </section>
  );
}

function HowItWorks() {
  const steps = [
    ['user-round-plus', 'Join the mesh', 'Pick a handle and switch on your link. You\u2019re instantly part of the neighbourhood network.'],
    ['route', 'Relay for peers', 'Your phone carries messages for nearby people — and theirs carry yours. Every hop is one neighbour helping another.'],
    ['globe', 'Reach the world', 'Whoever has a connection shares it. Messages hop across the mesh until they reach the open internet.'],
  ];
  return (
    <section style={{ background: 'var(--bg-sunken)', padding: '80px 0', borderTop: '1px solid var(--border-subtle)', borderBottom: '1px solid var(--border-subtle)' }}>
      <div style={wrap}>
        <div style={{ textAlign: 'center', marginBottom: 48 }}>
          <Badge tone="accent">How it works</Badge>
          <h2 style={{ ...H, fontSize: 40, marginTop: 14 }}>No towers. Just neighbours.</h2>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3,1fr)', gap: 24 }}>
          {steps.map(([ic, t, d], i) => (
            <Card key={t} elevation="sm" padding="lg">
              <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
                <span style={{ width: 48, height: 48, borderRadius: 'var(--radius-lg)', background: 'var(--primary-soft)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon n={ic} size={24} color="var(--primary-on-soft)" /></span>
                <span style={{ fontFamily: 'var(--font-mono)', fontSize: 13, color: 'var(--text-subtle)' }}>0{i + 1}</span>
              </div>
              <h3 style={{ ...H, fontSize: 22, marginBottom: 8 }}>{t}</h3>
              <p style={{ fontFamily: 'var(--font-sans)', fontSize: 16, lineHeight: 1.55, color: 'var(--text-muted)', margin: 0 }}>{d}</p>
            </Card>
          ))}
        </div>
      </div>
    </section>
  );
}

function Stats() {
  const stats = [['48k', 'peers relaying'], ['1.2M', 'messages carried daily'], ['312', 'neighbourhood meshes'], ['0', 'towers required']];
  return (
    <section style={{ ...wrap, padding: '72px 32px' }}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 24 }}>
        {stats.map(([n, l]) => (
          <div key={l} style={{ textAlign: 'center' }}>
            <div style={{ fontFamily: 'var(--font-display)', fontSize: 52, fontWeight: 800, color: 'var(--primary)', letterSpacing: '-0.03em' }}>{n}</div>
            <div style={{ fontFamily: 'var(--font-sans)', fontSize: 15, color: 'var(--text-muted)', marginTop: 4 }}>{l}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

function CTA() {
  return (
    <section style={{ ...wrap, paddingBottom: 80 }}>
      <div style={{ background: 'var(--terra-500)', borderRadius: 'var(--radius-2xl)', padding: '56px 48px', textAlign: 'center', color: '#fff', boxShadow: 'var(--shadow-lg)' }}>
        <h2 style={{ ...H, color: '#fff', fontSize: 40, marginBottom: 14 }}>Lend your link. Stay connected.</h2>
        <p style={{ fontFamily: 'var(--font-sans)', fontSize: 19, color: 'var(--terra-50)', maxWidth: 520, margin: '0 auto 28px', lineHeight: 1.5 }}>Every phone that joins makes the mesh stronger for everyone nearby. It takes two minutes.</p>
        <div style={{ display: 'flex', gap: 14, justifyContent: 'center' }}>
          <Button variant="soft" size="lg" iconRight={<Icon n="arrow-right" size={20} color="var(--primary-on-soft)" />}>Join the mesh</Button>
        </div>
      </div>
    </section>
  );
}

function Footer() {
  const cols = { Product: ['How it works', 'Coverage map', 'Download'], Community: ['Peer guidelines', 'Local meshes', 'Stories'], About: ['Mission', 'Open protocol', 'Contact'] };
  return (
    <footer style={{ background: 'var(--clay-800)', color: 'var(--clay-100)', padding: '56px 0 32px' }}>
      <div style={{ ...wrap, display: 'grid', gridTemplateColumns: '1.5fr 1fr 1fr 1fr', gap: 32 }}>
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 12 }}>
            <span style={{ width: 14, height: 14, borderRadius: '50%', background: 'var(--terra-400)' }} />
            <span style={{ fontFamily: 'var(--font-display)', fontSize: 22, fontWeight: 800, color: '#fff' }}>grasslink</span>
          </div>
          <p style={{ fontFamily: 'var(--font-sans)', fontSize: 14, color: 'var(--clay-300)', maxWidth: 260, lineHeight: 1.55 }}>A grassroots communication mesh that lives from the collective engagement of its peers.</p>
        </div>
        {Object.entries(cols).map(([h, items]) => (
          <div key={h}>
            <div style={{ fontFamily: 'var(--font-sans)', fontSize: 13, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.05em', color: 'var(--clay-400)', marginBottom: 14 }}>{h}</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {items.map((i) => <a key={i} href="#" style={{ fontFamily: 'var(--font-sans)', fontSize: 15, color: 'var(--clay-100)', textDecoration: 'none' }}>{i}</a>)}
            </div>
          </div>
        ))}
      </div>
      <div style={{ ...wrap, marginTop: 40, paddingTop: 20, borderTop: '1px solid var(--clay-700)', fontFamily: 'var(--font-sans)', fontSize: 13, color: 'var(--clay-400)' }}>© 2026 grasslink · Built by its peers</div>
    </footer>
  );
}

Object.assign(window, { GLSIcon: Icon, Nav, Hero, HowItWorks, Stats, CTA, Footer });
