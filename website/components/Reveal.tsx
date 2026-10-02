export function Reveal({children, as: Tag = "div"}: { children: React.ReactNode; delay?: number; as?: "div" | "li" | "section" | "header" }) {
  return <Tag className="reveal">{children}</Tag>;
}
