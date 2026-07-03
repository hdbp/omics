// PDF/PPTX export for the Layout collage. Both libraries are dynamically
// imported so their code only loads (as separate chunks) when a user actually
// clicks "Export as PDF"/"Export as PPTX" — the PNG path (already the common
// case) stays on the small main bundle.
//
// `cssWidth`/`cssHeight` must be the collage's true CSS-pixel content size
// (e.g. LayoutWorkspace's `contentSize`), NOT `canvas.width`/`canvas.height` —
// the canvas passed in is rendered at a fixed supersample scale (currently 2x)
// for crisper output, which has nothing to do with the browser's actual
// devicePixelRatio and would silently double the exported page/slide size if
// used to back out the "real" dimensions.

export async function downloadCanvasAsPdf(
  canvas: HTMLCanvasElement,
  cssWidth: number,
  cssHeight: number,
  filename: string
): Promise<void> {
  const { jsPDF } = await import('jspdf');
  const doc = new jsPDF({
    orientation: cssWidth >= cssHeight ? 'landscape' : 'portrait',
    unit: 'px',
    format: [cssWidth, cssHeight],
  });
  doc.addImage(canvas.toDataURL('image/png'), 'PNG', 0, 0, cssWidth, cssHeight);
  doc.save(filename);
}

const PPTX_DPI = 96; // treats the collage's CSS pixels as 96/inch, PowerPoint's usual default
const PPTX_MAX_INCHES = 56; // PowerPoint's own slide-size ceiling

export async function downloadCanvasAsPptx(
  canvas: HTMLCanvasElement,
  cssWidth: number,
  cssHeight: number,
  filename: string
): Promise<void> {
  const PptxGenJS = (await import('pptxgenjs')).default;
  const widthIn = Math.min(PPTX_MAX_INCHES, cssWidth / PPTX_DPI);
  const heightIn = Math.min(PPTX_MAX_INCHES, cssHeight / PPTX_DPI);

  const pres = new PptxGenJS();
  pres.defineLayout({ name: 'FCS_LAYOUT', width: widthIn, height: heightIn });
  pres.layout = 'FCS_LAYOUT';
  const slide = pres.addSlide();
  slide.addImage({ data: canvas.toDataURL('image/png'), x: 0, y: 0, w: widthIn, h: heightIn });
  await pres.writeFile({ fileName: filename });
}
