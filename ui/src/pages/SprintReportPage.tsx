import { useParams } from "react-router-dom";

// Placeholder — sprint report rendering shares DocPage's machinery once
// i-react-doc-renderer lands; kept as its own route/component per PRD-006 p5
// so reports and docs can diverge later without a routing change.
export function SprintReportPage() {
  const { slug } = useParams<{ slug: string }>();
  return (
    <section className="page">
      <h1>{slug}</h1>
      <p className="sub">Sprint report rendering lands here alongside i-react-doc-renderer.</p>
    </section>
  );
}
