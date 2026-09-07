export type LandingKind = "prds" | "docs" | "reports";

const TITLES: Record<LandingKind, string> = {
  prds: "PRDs",
  docs: "Docs",
  reports: "Reports",
};

// Placeholder — category listings from /api/docs land in i-react-landings
// once i-server-api exists.
export function LandingPage({ kind }: { kind: LandingKind }) {
  return (
    <section className="page">
      <h1>{TITLES[kind]}</h1>
      <p className="sub">The {TITLES[kind].toLowerCase()} listing lands here in i-react-landings.</p>
    </section>
  );
}
