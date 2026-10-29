import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Privacy Policy — Portal",
  description: "How Portal handles information when you use the app.",
};

export default function Privacy() {
  return (
    <main className="security-page">
      <header className="security-header">
        <Link className="brand" href="/" aria-label="Portal home">
          <span aria-hidden="true">&gt;_</span>
          <strong>PORTAL</strong>
        </Link>
        <Link href="/security">SECURITY MODEL</Link>
      </header>

      <article className="security-article">
        <div className="security-hero">
          <p className="section-kicker">Privacy policy / August 13, 2026</p>
          <h1>Your terminal stays yours.</h1>
          <p className="security-lede">
            Portal does not use advertising, analytics, tracking, or a Portal
            account. Remote access is optional and terminal contents are
            end-to-end encrypted before leaving your devices.
          </p>
        </div>

        <section aria-labelledby="scope-title">
          <p className="section-kicker">01 / Scope</p>
          <h2 id="scope-title">What this policy covers.</h2>
          <p>
            This policy describes how Portal Terminal for Mac and iPhone and
            the Portal relay handle information. Portal is provided by Max
            Howell. It does not apply to Apple services such as iCloud,
            iCloud Keychain, or the App Store, which Apple operates under its
            own privacy policy.
          </p>
        </section>

        <section aria-labelledby="local-title">
          <p className="section-kicker">02 / Local use</p>
          <h2 id="local-title">Local sessions stay on your Mac.</h2>
          <p>
            Commands, terminal output, session names, paths, and local session
            state remain on your Mac when you use Portal locally. Portal does
            not send local terminal sessions to us unless you enable Remote
            Access.
          </p>
        </section>

        <section aria-labelledby="remote-title">
          <p className="section-kicker">03 / Remote access</p>
          <h2 id="remote-title">What leaves your devices.</h2>
          <p>
            When Remote Access is enabled, Portal sends encrypted terminal
            frames and an encrypted session catalog through the Portal relay.
            Encryption keys are created on-device and synchronized between
            your devices using iCloud Keychain. The relay cannot decrypt
            commands, keystrokes, output, paths, or session names.
          </p>
          <p>
            Like any internet service, the relay and its hosting and network
            providers can process connection information needed to deliver
            requests, including IP addresses, timing, message sizes, an opaque
            room identifier, and the number of connected peers. Portal does
            not use this information for advertising or tracking.
          </p>
        </section>

        <section aria-labelledby="retention-title">
          <p className="section-kicker">04 / Storage and retention</p>
          <h2 id="retention-title">The relay stores ciphertext, not content.</h2>
          <p>
            Live terminal frames are held in memory only long enough to relay
            them to connected devices and are not persisted or logged by the
            Portal relay. The relay stores one encrypted session-catalog blob
            per opaque room; each update replaces the previous blob and no
            history is kept. A catalog inactive for 30 days is deleted when it
            is next read and may be deleted sooner after a subscription ends.
          </p>
          <p>
            If you contact us for support, we receive the information you
            choose to provide and keep it only as long as reasonably necessary
            to respond and maintain a record of the request.
          </p>
        </section>

        <section aria-labelledby="apple-title">
          <p className="section-kicker">05 / Apple services</p>
          <h2 id="apple-title">Apple handles iCloud and purchases.</h2>
          <p>
            Portal uses iCloud Keychain to synchronize its remote-access key
            between devices signed in to your Apple Account. Subscriptions are
            purchased and managed through the App Store. We do not receive
            your Apple Account password or payment-card information.
          </p>
        </section>

        <section aria-labelledby="sharing-title">
          <p className="section-kicker">06 / Sharing</p>
          <h2 id="sharing-title">No selling, advertising, or tracking.</h2>
          <p>
            We do not sell personal information or share it for targeted
            advertising. Information may be processed by infrastructure
            providers solely to operate the relay, by Apple when you use Apple
            services, or when required by law or necessary to protect users,
            the service, or the public.
          </p>
        </section>

        <section aria-labelledby="choices-title">
          <p className="section-kicker">07 / Your choices</p>
          <h2 id="choices-title">Remote access is optional.</h2>
          <p>
            You can use Portal locally without Remote Access. You can disable
            Remote Access and end terminal sessions from your Mac at any time.
            Portal has no user account to delete. For questions, support
            records, or privacy requests, email us at{" "}
            <a href="mailto:mxcl@me.com">mxcl@me.com</a>.
          </p>
        </section>

        <section aria-labelledby="changes-title">
          <p className="section-kicker">08 / Changes</p>
          <h2 id="changes-title">Policy updates.</h2>
          <p>
            We may update this policy as Portal changes. The effective date at
            the top of this page identifies the current version.
          </p>
        </section>

        <aside>
          <strong>More technical detail</strong>
          <p>
            Read Portal&apos;s <Link href="/security">security model</Link> for
            its encryption, network boundaries, relay storage, and limitations.
          </p>
        </aside>
      </article>

      <footer>
        <Link className="brand" href="/">
          <span aria-hidden="true">&gt;_</span>
          <strong>PORTAL</strong>
        </Link>
        <p>PRIVACY POLICY</p>
        <p>© 2026</p>
      </footer>
    </main>
  );
}
