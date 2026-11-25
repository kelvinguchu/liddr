import { useState } from "react";
import { turnsLeft } from "@/lib/orientation";

// A document photo, the right way up. A portrait ID or licence is drawn turned
// a quarter to the left inside a landscape box: the box takes the turned shape,
// and the image fills it through container units, so it never overflows.
export function DocumentImage({ src, alt, documentType }: { src: string; alt: string; documentType: string }) {
  const [size, setSize] = useState<{ width: number; height: number } | null>(null);
  const plain = "max-h-full max-w-full rounded-md object-contain sm:max-h-[calc(100dvh-14rem)]";
  const load = (event: React.SyntheticEvent<HTMLImageElement>) => setSize({ width: event.currentTarget.naturalWidth, height: event.currentTarget.naturalHeight });

  if (!size || !turnsLeft(documentType, size.width, size.height)) {
    // Hidden until measured when it might need turning, so a sideways card never flashes up.
    const measuring = !size && turnsLeft(documentType, 1, 2);
    return <img src={src} alt={alt} referrerPolicy="no-referrer" onLoad={load} className={measuring ? `${plain} invisible` : plain} />;
  }
  const ratio = size.height / size.width;
  return (
    <div
      className="relative overflow-hidden rounded-md [container-type:size]"
      style={{ aspectRatio: `${size.height} / ${size.width}`, width: `min(100%, calc((100dvh - 14rem) * ${ratio}))` }}
    >
      <img
        src={src}
        alt={alt}
        referrerPolicy="no-referrer"
        className="absolute top-1/2 left-1/2 max-w-none -translate-x-1/2 -translate-y-1/2 -rotate-90"
        style={{ width: "100cqh", height: "100cqw" }}
      />
    </div>
  );
}
