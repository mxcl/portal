import { ParticleObject } from "@/components/canvasui/ParticleObject";

const features = [
  {
    number: "01",
    title: "Commands become places.",
    copy: "Every command and its output lives in a block you can scan, revisit, and act on.",
  },
  {
    number: "02",
    title: "Sessions outlive windows.",
    copy: "Close a tab. Quit Portal. Your shell keeps running until you decide it is done.",
  },
  {
    number: "03",
    title: "Your Macs feel like one.",
    copy: "Local and remote sessions share one picker. Rejoin the right shell from the Mac in front of you.",
  },
];

export default function Home() {
  return (
    <main>
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Portal home">
          <span aria-hidden="true">&gt;_</span>
          <strong>PORTAL</strong>
        </a>
        <div className="header-meta">
          <span>macOS</span>
          <a href="#inside">SEE INSIDE</a>
        </div>
      </header>

      <section className="hero" id="top">
        <div className="hero-copy">
          <p className="eyebrow">
            <span className="live-dot" />
            Persistent shell transport online
          </p>
          <h1>
            <span>The terminal</span>
            <span>that never</span>
            <span className="gradient-text">leaves.</span>
          </h1>
          <p className="lede">
            Portal turns commands into blocks and keeps every session alive—
            through closed tabs, app quits, and the space between your Macs.
          </p>
          <a className="primary-action" href="#inside">
            Enter Portal
            <span aria-hidden="true">↓</span>
          </a>
        </div>

        <div className="portal-stage" aria-hidden="true">
          <div className="portal-aura" />
          <img className="portal-core" src="/portal-icon.png" alt="" />
          <ParticleObject
            className="portal-particles"
            src="/portal-icon.png"
            count={22000}
            size={2.8}
            sizeVariance={0.8}
            radius={150}
            strength={1.25}
            swirl={1.35}
            spring={0.7}
            damping={0.28}
            drift={0.85}
            scale={3.35}
            orbit={false}
            zoom={false}
            floatIntensity={0.35}
            rotationIntensity={0.08}
            floatSpeed={0.75}
          />
          <div className="portal-flare" />
        </div>

        <div className="hero-index" aria-hidden="true">
          <span>001</span>
          <i />
          <span>PORTAL / TERMINAL</span>
        </div>
      </section>

      <section className="statement" id="inside">
        <p className="section-kicker">The shell should belong to you</p>
        <h2>
          Close the tab.
          <br />
          <span>Not the session.</span>
        </h2>
        <p className="statement-copy">
          Portal separates the life of your shell from the life of a window.
          Your work waits exactly where you left it.
        </p>
      </section>

      <section className="product-shot">
        <div className="shot-frame">
          <div className="shot-bar">
            <span>PORTAL / LOCAL SESSION</span>
            <span>CONNECTED · 00:42:17</span>
          </div>
          <img
            src="/session-blocks.webp"
            alt="Portal showing terminal commands arranged in clear output blocks"
          />
        </div>
        <p className="shot-caption">
          <span>01</span>
          A terminal designed around what you did, not just what flew past.
        </p>
      </section>

      <section className="features" aria-label="Portal features">
        {features.map((feature) => (
          <article key={feature.number}>
            <span className="feature-number">{feature.number}</span>
            <h3>{feature.title}</h3>
            <p>{feature.copy}</p>
          </article>
        ))}
      </section>

      <section className="remote">
        <div className="remote-copy">
          <p className="section-kicker">Distance: irrelevant</p>
          <h2>
            One portal.
            <br />
            Every shell.
          </h2>
          <p>
            Attach to persistent sessions on another Mac over SSH. No new
            passwords, no open terminal listener, no pretending remote work is
            local.
          </p>
        </div>
        <div className="remote-frame">
          <img
            src="/remote-sessions.webp"
            alt="Portal session picker showing available sessions"
          />
        </div>
      </section>

      <section className="finale">
        <img src="/portal-icon.png" alt="" aria-hidden="true" />
        <div>
          <p className="section-kicker">The command line, with continuity</p>
          <h2>Your work is still there.</h2>
          <p>Portal for macOS. Built on libghostty. Made for long-running ideas.</p>
          <a className="primary-action" href="#top">
            Back to the portal
            <span aria-hidden="true">↑</span>
          </a>
        </div>
      </section>

      <footer>
        <a className="brand" href="#top">
          <span aria-hidden="true">&gt;_</span>
          <strong>PORTAL</strong>
        </a>
        <p>YOUR SESSION IS STILL RUNNING.</p>
        <p>© 2026</p>
      </footer>
    </main>
  );
}
