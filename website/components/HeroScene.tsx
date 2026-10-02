import { Maximize2 } from "lucide-react";

export function HeroScene() {
  return <div className="cinema-scene">
    <div className="product-stage">
      <div className="stage-device">
        <img src="/hero-services.png" alt="RSSum All Articles view with RSS and Reddit subscriptions in the sidebar" width={2360} height={1640} decoding="async" fetchPriority="high" />
      </div>
    </div>
    <div className="cinema-scene-tools">
      <a className="icon-button" href="/hero-services.png" target="_blank" rel="noreferrer" aria-label="Open full-size app screenshot" title="Open full-size app screenshot"><Maximize2 size={17} aria-hidden="true" /></a>
    </div>
  </div>;
}
