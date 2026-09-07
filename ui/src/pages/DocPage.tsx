import { useParams } from "react-router-dom";

// Placeholder — multi-page nav, response boxes, reply threads, autosave land
// here in i-react-doc-renderer once i-sqlite-schema and i-server-api exist.
// The route already receives :slug so that issue can wire useDoc(slug) in
// without changing App.tsx's routing.
export function DocPage() {
  const { slug } = useParams<{ slug: string }>();
  return (
    <section className="page">
      <h1>{slug}</h1>
      <p className="sub">Doc rendering (pages, response boxes, reply threads) lands here in i-react-doc-renderer.</p>
    </section>
  );
}
