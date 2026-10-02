"use client";

import { useEffect, useRef, useState } from "react";

export function ProductStage({ src, alt, moving }: { src: string; alt: string; moving: boolean }) {
  const host = useRef<HTMLDivElement>(null);
  const device = useRef<HTMLDivElement>(null);
  const screenshot = useRef<HTMLImageElement>(null);
  const motion = useRef(moving);
  const wake = useRef<(() => void) | null>(null);
  const [loadedSource, setLoadedSource] = useState("");
  motion.current = moving;

  useEffect(() => { wake.current?.(); }, [moving]);
  useEffect(() => {
    if (screenshot.current?.complete && screenshot.current.naturalWidth > 0) setLoadedSource(src);
  }, [src]);

  useEffect(() => {
    const element = host.current;
    const frameElement = device.current;
    if (!element || !frameElement) return;
    let disposed = false;
    let cleanup: (() => void) | undefined;
    const preference = matchMedia("(prefers-reduced-motion: reduce)");

    async function start() {
      const { Euler, Matrix4, MathUtils } = await import("three");
      if (disposed) return;
      const rotation = new Euler();
      const matrix = new Matrix4();
      let frame = 0, visible = true, last = 0, elapsed = 0;
      let pointerX = 0, pointerY = 0;
      const render = () => {
        frame = 0;
        if (disposed || !visible || document.hidden) return;
        if (preference.matches) {
          rotation.set(0, 0, 0);
          frameElement!.style.removeProperty("--device-rotation");
          element!.dataset.rotation = "0,0,0";
          return;
        }
        const now = performance.now();
        const dt = Math.min((now - (last || now)) / 1000, .05);
        last = now;
        const enabled = motion.current && !preference.matches;
        if (enabled) elapsed += dt;
        rotation.x = MathUtils.damp(rotation.x, enabled ? pointerY * .025 : 0, 6, dt);
        rotation.y = MathUtils.damp(rotation.y, enabled ? pointerX * .035 : 0, 6, dt);
        rotation.z = MathUtils.damp(rotation.z, enabled ? Math.sin(elapsed * .45) * .002 : 0, 6, dt);
        // Three.js supplies the transform; the full screenshot remains a native image.
        matrix.makeRotationFromEuler(rotation);
        frameElement!.style.setProperty("--device-rotation", `matrix3d(${matrix.elements.join(",")})`);
        element!.dataset.frames = String(Math.round(elapsed * 60));
        element!.dataset.rotation = [rotation.x, rotation.y, rotation.z].join(",");
        if (enabled || Math.abs(rotation.x) + Math.abs(rotation.y) + Math.abs(rotation.z) > .0001) frame = requestAnimationFrame(render);
      };
      const resume = () => {
        if (!frame && visible && !document.hidden && !preference.matches) { last = 0; frame = requestAnimationFrame(render); }
      };
      const move = (event: PointerEvent) => {
        if (event.pointerType !== "mouse") return;
        const bounds = element!.getBoundingClientRect();
        pointerX = (event.clientX - bounds.left) / bounds.width * 2 - 1;
        pointerY = (event.clientY - bounds.top) / bounds.height * 2 - 1;
        resume();
      };
      const leave = () => { pointerX = 0; pointerY = 0; resume(); };
      const resetMotion = () => {
        if (preference.matches) {
          cancelAnimationFrame(frame); frame = 0;
          rotation.set(0, 0, 0);
          frameElement!.style.removeProperty("--device-rotation");
        } else resume();
      };
      const visibility = () => {
        if (document.hidden) { cancelAnimationFrame(frame); frame = 0; }
        else resume();
      };
      const observer = new IntersectionObserver(([entry]) => {
        visible = entry.isIntersecting;
        if (visible) resume();
        else { cancelAnimationFrame(frame); frame = 0; }
      });
      observer.observe(element!);
      element!.addEventListener("pointermove", move);
      element!.addEventListener("pointerleave", leave);
      preference.addEventListener("change", resetMotion);
      document.addEventListener("visibilitychange", visibility);
      wake.current = resume;
      resume();
      cleanup = () => {
        cancelAnimationFrame(frame);
        observer.disconnect();
        element!.removeEventListener("pointermove", move);
        element!.removeEventListener("pointerleave", leave);
        preference.removeEventListener("change", resetMotion);
        document.removeEventListener("visibilitychange", visibility);
        frameElement!.style.removeProperty("--device-rotation");
        wake.current = null;
      };
    }
    void start().catch(() => { /* The native image remains usable without animation. */ });
    return () => { disposed = true; cleanup?.(); };
  }, []);

  return <div ref={host} className="product-stage" data-ready={loadedSource === src}>
    <div ref={device} className="stage-device">
      <img ref={screenshot} src={src} alt={alt} width={2360} height={1640} decoding="async" fetchPriority="high" onLoad={() => setLoadedSource(src)} />
    </div>
  </div>;
}
