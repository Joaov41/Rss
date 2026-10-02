export function PageIntro({ label, title, description }: { label: string; title: string; description: string }) {
  return (
    <header className="page-intro">
      <p className="page-label">{label}</p>
      <h1>{title}</h1>
      <p>{description}</p>
    </header>
  );
}
