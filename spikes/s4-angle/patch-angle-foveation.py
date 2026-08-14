#!/usr/bin/env python3
"""Rüstet ANGLEs Metal-Backend um Metals Rasterization Rate Maps nach.

Ohne diese Ergänzung ist auf visionOS keine Foveation möglich:
`grep -ri foveat src/libANGLE/renderer/metal/` liefert im Original nichts. Die
Foveation-Extensions, die ANGLE führt (GL_QCOM_framebuffer_foveated,
GL_EXT_fragment_shading_rate), sind für andere Backends implementiert.

Das ist entscheidend, nicht kosmetisch: Ohne Foveation muss über das gesamte
Blickfeld in voller Dichte gerastert werden, und CompositorServices deckelt die
Drawable entsprechend. Die Vision Pro käme damit nicht über das hinaus, was
günstigere Headsets liefern — ihr wesentlicher Vorteil ginge verloren.

Anders als `patch-angle-visionos.py`, das nur Chromiums Build-System anfasst,
greift dieser Patch in ANGLEs Renderer ein und muss bei ANGLE-Updates
nachgezogen werden.

Aufruf:

    python3 patch-angle-foveation.py angle/

Idempotent — bereits gepatchte Stellen werden übersprungen.
"""

import sys
from pathlib import Path

METAL = "src/libANGLE/renderer/metal/"

PATCHES = [
    # ------------------------------------------------------------------
    # 1. Feld in RenderPassDesc
    # ------------------------------------------------------------------
    (
        METAL + "mtl_state_cache.h",
        """    uint32_t numColorAttachments = 0;
    uint32_t rasterSampleCount   = 1;
    uint32_t defaultWidth        = 0;
    uint32_t defaultHeight       = 0;
};""",
        """    uint32_t numColorAttachments = 0;
    uint32_t rasterSampleCount   = 1;
    uint32_t defaultWidth        = 0;
    uint32_t defaultHeight       = 0;

    // Fork-Ergänzung: Metals Rasterization Rate Map für Foveation.
    //
    // Bewusst ein roher, nicht besitzender Zeiger. Die Struktur dient als
    // Cache-Schlüssel, wird häufig kopiert und verglichen — ein ObjC-Objekt
    // mit Retain/Release darin wäre teuer und würde den Vergleich
    // verkomplizieren. Für die Lebensdauer sorgt der Aufrufer; auf visionOS
    // gehört die Map der Drawable und lebt mindestens den Frame lang.
    const void *rasterizationRateMap = nullptr;
};""",
        "Feld für die Rate Map in RenderPassDesc",
    ),
    # ------------------------------------------------------------------
    # 2. In den Gleichheitsvergleich aufnehmen
    # ------------------------------------------------------------------
    (
        METAL + "mtl_state_cache.mm",
        """    return depthAttachment == other.depthAttachment &&
           stencilAttachment == other.stencilAttachment && defaultWidth == other.defaultWidth &&
           defaultHeight == other.defaultHeight && rasterSampleCount == other.rasterSampleCount;""",
        """    return depthAttachment == other.depthAttachment &&
           stencilAttachment == other.stencilAttachment && defaultWidth == other.defaultWidth &&
           defaultHeight == other.defaultHeight && rasterSampleCount == other.rasterSampleCount &&
           // Muss mit verglichen werden: der Descriptor ist Cache-Schlüssel für
           // Render-Encoder. Ohne diesen Vergleich würde ein Pass mit anderer
           // Rate Map fälschlich als identisch gelten und die alte Map behalten.
           rasterizationRateMap == other.rasterizationRateMap;""",
        "Rate Map in RenderPassDesc::operator== aufnehmen",
    ),
    # ------------------------------------------------------------------
    # 3. An den MTLRenderPassDescriptor durchreichen
    # ------------------------------------------------------------------
    (
        METAL + "mtl_state_cache.mm",
        """    else
    {
        objCDesc.renderTargetWidth  = 0;
        objCDesc.renderTargetHeight = 0;
        // No need to reset defaultRasterSampleCount as it is only applied when no attachments are
        // provided.
    }
}""",
        """    else
    {
        objCDesc.renderTargetWidth  = 0;
        objCDesc.renderTargetHeight = 0;
        // No need to reset defaultRasterSampleCount as it is only applied when no attachments are
        // provided.
    }

    // Fork-Ergänzung: Foveation. Immer zuweisen, auch nil — die Descriptors
    // werden wiederverwendet, und eine übrig gebliebene Map aus einem früheren
    // Pass würde still weiterwirken.
    if (@available(iOS 13.0, macOS 10.15.4, *))
    {
        objCDesc.rasterizationRateMap = (__bridge id<MTLRasterizationRateMap>)(
            const_cast<void *>(rasterizationRateMap));
    }
}""",
        "Rate Map in convertToMetalDesc setzen",
    ),
    # ------------------------------------------------------------------
    # 4. Am Framebuffer merken und bei jedem Neuaufbau wieder eintragen
    # ------------------------------------------------------------------
    (
        METAL + "FrameBufferMtl.h",
        "    mtl::RenderPassDesc mRenderPassDesc;",
        """    mtl::RenderPassDesc mRenderPassDesc;

    // Fork-Ergänzung: separat gehalten, weil prepareRenderPass() den
    // Descriptor bei jeder Synchronisierung neu aufbaut und ein direkt dort
    // gesetzter Wert dabei verloren ginge.
    const void *mRasterizationRateMap = nullptr;

  public:
    void setRasterizationRateMap(const void *map)
    {
        mRasterizationRateMap             = map;
        mRenderPassDesc.rasterizationRateMap = map;
    }
    const void *getRasterizationRateMap() const { return mRasterizationRateMap; }

  private:""",
        "Rate Map am Framebuffer merken, samt Setter und Getter",
    ),
    # ------------------------------------------------------------------
    # 4b. Scissor in Screen-Koordinaten rechnen
    #
    # Der eigentliche Knackpunkt. ANGLE klemmt den Scissor gegen die
    # *physischen* Framebuffer-Maße, der Viewport ist bei aktiver Rate Map aber
    # in *Screen*-Koordinaten angegeben. Bei 5087x4081 Screen auf 2048x1984
    # physisch bleiben so nur rund 40 % der Breite und 49 % der Höhe übrig —
    # sichtbar als abgeschnittenes Bild in einer Ecke.
    #
    # Die Screen-Größe muss nicht durchgereicht werden, sie steht in der Map.
    # ------------------------------------------------------------------
    (
        METAL + "ContextMtl.mm",
        """    FramebufferMtl *framebufferMtl = mtl::GetImpl(glState.getDrawFramebuffer());
    gl::Rectangle renderArea       = framebufferMtl->getCompleteRenderArea();

    ANGLE_MTL_LOG("renderArea = %d,%d,%d,%d", renderArea.x, renderArea.y, renderArea.width,
                  renderArea.height);""",
        """    FramebufferMtl *framebufferMtl = mtl::GetImpl(glState.getDrawFramebuffer());
    gl::Rectangle renderArea       = framebufferMtl->getCompleteRenderArea();

    // Fork-Ergänzung: Bei aktiver Rasterization Rate Map ist der Viewport in
    // Screen-Koordinaten angegeben, die Render-Ziel-Maße sind physisch und
    // kleiner. Ohne diese Korrektur schneidet der Scissor das Bild auf den
    // physischen Bereich zu, und sichtbar bleibt nur eine Ecke.
    if (const void *rateMap = framebufferMtl->getRasterizationRateMap())
    {
        if (@available(iOS 13.0, macOS 10.15.4, *))
        {
            MTLSize screen = [(__bridge id<MTLRasterizationRateMap>)const_cast<void *>(rateMap)
                screenSize];
            renderArea = gl::Rectangle(0, 0, static_cast<int>(screen.width),
                                       static_cast<int>(screen.height));
        }
    }

    ANGLE_MTL_LOG("renderArea = %d,%d,%d,%d", renderArea.x, renderArea.y, renderArea.width,
                  renderArea.height);""",
        "Scissor bei aktiver Rate Map in Screen-Koordinaten rechnen",
    ),
    # ------------------------------------------------------------------
    # 4c. Die Scissor-Obergrenze anheben
    #
    # Letztes Glied der Kette. mRenderPassMaxScissorRect startet bei "unendlich"
    # und wird von jedem Anhang auf dessen physische Texturgröße heruntergezogen;
    # setScissorRect() klemmt anschließend darauf. Ein Scissor in
    # Screen-Koordinaten (5087x4081) landet so wieder bei 2048x1984 — und genau
    # dieser Ausschnitt bleibt vom Bild übrig.
    # ------------------------------------------------------------------
    (
        METAL + "mtl_command_buffer.mm",
        """    initAttachmentWriteDependencyAndScissorRect(mRenderPassDesc.stencilAttachment);

    // Convert to Objective-C descriptor""",
        """    initAttachmentWriteDependencyAndScissorRect(mRenderPassDesc.stencilAttachment);

    // Fork-Ergänzung: Bei aktiver Rasterization Rate Map sind Viewport und
    // Scissor in Screen-Koordinaten angegeben, die Anhänge dagegen physisch und
    // kleiner. Ohne diese Anhebung klemmt setScissorRect() auf die physische
    // Größe zurück und schneidet den Großteil des Bildes weg.
    if (mRenderPassDesc.rasterizationRateMap != nullptr)
    {
        if (@available(iOS 13.0, macOS 10.15.4, *))
        {
            MTLSize screen = [(__bridge id<MTLRasterizationRateMap>)const_cast<void *>(
                mRenderPassDesc.rasterizationRateMap) screenSize];
            mRenderPassMaxScissorRect.width  = screen.width;
            mRenderPassMaxScissorRect.height = screen.height;
        }
    }

    // Convert to Objective-C descriptor""",
        "Scissor-Obergrenze bei aktiver Rate Map auf die Screen-Größe anheben",
    ),
    (
        METAL + "FrameBufferMtl.mm",
        """    mtl::RenderPassDesc &desc = *pDescOut;
""",
        """    mtl::RenderPassDesc &desc = *pDescOut;

    // Fork-Ergänzung: gemerkte Rate Map wieder eintragen. prepareRenderPass()
    // baut den Descriptor sonst ohne sie neu auf, und die Foveation ginge beim
    // ersten Zustandswechsel still verloren.
    desc.rasterizationRateMap = mRasterizationRateMap;
""",
        "Rate Map beim Neuaufbau des Render-Passes erhalten",
    ),
    # ------------------------------------------------------------------
    # 5a. Implementierung in Objective-C++
    #
    # Muss hier liegen und nicht in global_state.cpp: FrameBufferMtl.h zieht
    # Objective-C-Header nach, die eine reine .cpp nicht übersetzen kann.
    # ------------------------------------------------------------------
    (
        METAL + "FrameBufferMtl.mm",
        """    return angle::Result::Continue;
}

}  // namespace rx""",
        """    return angle::Result::Continue;
}

// Fork-Ergänzung: Foveation. Setzt die Rasterization Rate Map auf dem aktuell
// gebundenen Draw-Framebuffer. Aufgerufen aus der exportierten C-Hülle in
// global_state.cpp, die selbst keine Objective-C-Header einbinden darf.
namespace mtl
{
void SetDrawFramebufferRateMap(gl::Context *context, const void *rateMap)
{
    gl::Framebuffer *framebuffer = context->getState().getDrawFramebuffer();
    if (framebuffer == nullptr)
    {
        return;
    }
    FramebufferMtl *impl = GetImpl(framebuffer);
    if (impl != nullptr)
    {
        impl->setRasterizationRateMap(rateMap);
    }
}
}  // namespace mtl

}  // namespace rx""",
        "Implementierung SetDrawFramebufferRateMap in FrameBufferMtl.mm",
    ),
    # ------------------------------------------------------------------
    # 5b. Exportierte C-Hülle
    # ------------------------------------------------------------------
    (
        "src/libGLESv2/global_state.cpp",
        "#endif  // defined(ANGLE_PLATFORM_WINDOWS) && !defined(ANGLE_STATIC)",
        """#endif  // defined(ANGLE_PLATFORM_WINDOWS) && !defined(ANGLE_STATIC)

// ---------------------------------------------------------------------------
// Fork-Ergänzung: Foveation auf visionOS
//
// Bewusst eine schlichte exportierte C-Funktion statt einer vollwertigen
// GL-Extension. Eine Extension würde ANGLEs generierte Entry-Point-Tabellen
// berühren, die bei jedem Update neu erzeugt werden — der Patch wäre nach
// jedem Rebase kaputt. Diese eine Funktion überlebt das.
//
// Die Implementierung liegt in FrameBufferMtl.mm: hier dürfen keine
// Objective-C-Header eingebunden werden, weil diese Datei als reines C++
// übersetzt wird.
//
// `rateMap` ist ein id<MTLRasterizationRateMap>, nicht besitzend. Der Aufrufer
// garantiert, dass sie mindestens bis zum Absenden des Frames lebt; auf
// visionOS gehört sie der Drawable und erfüllt das von selbst.
// nullptr schaltet Foveation für den aktuellen Draw-Framebuffer wieder ab.
// ---------------------------------------------------------------------------
#if defined(ANGLE_ENABLE_METAL)
#    include "export.h"

namespace rx
{
namespace mtl
{
void SetDrawFramebufferRateMap(gl::Context *context, const void *rateMap);
}  // namespace mtl
}  // namespace rx

extern "C" ANGLE_EXPORT void ANGLESetDrawFramebufferRateMapMTL(const void *rateMap)
{
    gl::Context *context = gl::GetValidGlobalContext();
    if (context != nullptr)
    {
        rx::mtl::SetDrawFramebufferRateMap(context, rateMap);
    }
}
#endif  // defined(ANGLE_ENABLE_METAL)""",
        "Exportierte C-Hülle ANGLESetDrawFramebufferRateMapMTL",
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Aufruf: {sys.argv[0]} <pfad-zum-angle-checkout>")
        return 2

    root = Path(sys.argv[1])
    if not (root / METAL).is_dir():
        print(f"FEHLER: {root} enthält kein Metal-Backend")
        return 1

    applied = skipped = failed = 0

    for rel, needle, replacement, description in PATCHES:
        path = root / rel
        if not path.is_file():
            print(f"  FEHLT   {rel}")
            failed += 1
            continue

        text = path.read_text()
        if replacement in text:
            print(f"  bereits {rel}: {description}")
            skipped += 1
            continue
        if needle not in text:
            print(f"  FEHLER  {rel}: Suchtext nicht gefunden ({description})")
            failed += 1
            continue

        path.write_text(text.replace(needle, replacement, 1))
        print(f"  ok      {rel}: {description}")
        applied += 1

    print(f"\n{applied} angewandt, {skipped} bereits vorhanden, {failed} fehlgeschlagen")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
