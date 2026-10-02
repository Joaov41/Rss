import { SiteShell } from "./SiteShell";

type LegalDocumentProps = {
  title: string;
  description: string;
  effectiveDate: string;
  children: React.ReactNode;
};

export function LegalDocument({ title, description, effectiveDate, children }: LegalDocumentProps) {
  return (
    <SiteShell>
      <main id="main-content" className="inner-page legal-page">
        <header className="legal-intro">
          <p className="page-label">Legal</p>
          <h1>{title}</h1>
          <p>{description}</p>
        </header>
        <div className="legal-layout">
          <aside className="legal-summary" aria-label="Document information">
            <strong>{title}</strong>
            <p>Effective {effectiveDate}</p>
            <p>RSSum for iPhone, iPad, and Mac</p>
          </aside>
          <article className="legal-content">{children}</article>
        </div>
      </main>
    </SiteShell>
  );
}
