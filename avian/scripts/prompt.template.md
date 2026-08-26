# Bird illustration prompt

The prompt sent to Gemini for every illustration.

Three text placeholders get replaced per request:

- `{sci_name}` is the binomial Latin name, e.g. `Calypte anna`
- `{com_name}` is the English common name, e.g. `Anna's Hummingbird`
- `{pose}` is either `perched` (pose 1) or `in flight with wings spread` (pose 2)

`pregen.py` also attaches up to three reference images per request:

- A POSITIVE anatomy reference (Wikipedia photo of the target species). Anchors species identity, markings, and plumage.
- An OPTIONAL anti-reference (a photo of a similar-looking species the model drifts toward). Attached automatically for genera where the prior collapses: a Blue Jay for small blue corvids, a Barn Swallow for other swallows. The `{anti_ref_line}` placeholder is rewritten per-species.
- A POSITIVE style reference (a real Edo-period kachō-e print by Ohara Koson or Hiroshi Yoshida). The species in the print is irrelevant - only its painting style is borrowed.

---

## Prompt

Generate a {pose} {com_name} ({sci_name}) in the style of an Edo-period Japanese kachō-e woodblock print, matching the painting technique of IMAGE 2 closely. Look at IMAGE 2: the bird is rendered with VERY FEW MARKS. The body is essentially 2-4 flat color zones with sharp boundaries. There is almost no internal texture on the body - no feather-by-feather rendering, no pen-line stippling, no gradient shading. The bird in IMAGE 2 looks like it was painted with maybe 30 brush strokes total. YOUR output should look the same: a few flat color zones, a few confident outline strokes, an accent stroke or two for major wing or tail markings, and that's it.

Confident sumi-e ink linework with soft watercolor washes. Earthy, restrained palette: burnt umber, ochre, indigo, vermillion, muted greens. The body should look like flat painted paper - not a textured surface, not shaded volume. If the species has subtle plumage variation (streaking, mottling, fine barring), ABSTRACT it into 2-3 broad zones rather than rendering it literally. Eye, beak, and feet drawn with crisp ink - these are the only places where confident dark line is appropriate.

The bird is isolated against a CONSISTENT PURE MAGENTA CHROMA BACKGROUND (#FF00FF).

The BACKGROUND ONLY must be completely flat and uniform across the entire frame, edge to edge. Every background pixel should be the same pure magenta color (#FF00FF), with NO gradient, NO tonal variation, NO lighting variation, NO paper texture, NO watercolor wash, NO grain, NO vignette, NO glow, and NO shadow.

This flat-background requirement applies ONLY to the background. Do NOT flatten or simplify the bird because of the chroma background. The bird must retain the Edo-period kachō-e painting style described above, including its intended flat painted color zones, watercolor washes, ink work, natural tonal variation, and species-specific colors.

Keep a clean, clearly defined boundary between the bird and the magenta background. Do NOT allow magenta color spill, reflected magenta light, magenta halos, or magenta tinting on the bird's feathers, beak, legs, feet, or outline.

The magenta ground is the ONLY background element: NO branch, NO twig, NO perch, NO leaves, NO foliage, NO substrate, NO scenery, NO sky, NO moon, NO water. The perch is purely implied by toe posture - it is NEVER rendered. NO border or frame, NO text or signature.

Composition: the bird occupies one-third to one-half of the frame. Leave generous negative space (just the solid magenta chroma background) around it. The image should feel sparse and confident, not packed with detail.

The ENTIRE bird must fit within the image frame: head, both wings (fully extended for flight pose), full tail, both legs, both feet, beak. Do NOT crop the wings, tail, legs, or any body part at the edge of the frame. Leave generous padding on all sides.

### Reference handling

- IMAGE 1 (positive, anatomy) IS {com_name}. Match its proportions, head color, throat, wing pattern, back color, tail pattern, leg color. If the reference shows non-breeding or worn plumage, render the brightest BREEDING (adult-summer) plumage instead - render the most diagnostic, recognizable version of the species.
{anti_ref_line}
- IMAGE 3 (positive, style) is a real Edo-period kachō-e woodblock print. The bird in IMAGE 3 is a DIFFERENT species - IGNORE its species, only borrow its painting style. Render the bird in IMAGE 3's painting style. DO NOT copy any compositional elements from IMAGE 3 (branches, leaves, water, moon, scenery).

Treat IMAGE 1 for anatomy and color information ONLY. Treat IMAGE 3 for style ONLY. The output should look like an Edo-period woodblock print of the species in IMAGE 1, painted by the artist of IMAGE 3.

### Anatomy

- EXACTLY TWO wings (no more, no less - count them: one left, one right). EXACTLY TWO legs. EXACTLY ONE head. EXACTLY ONE beak. EXACTLY ONE tail.
- Posture, color, markings, and body proportions match IMAGE 1 / {com_name} field-guide references.
- Pay particular attention to species-specific patterns. Do NOT default to generic markings: if the reference shows a uniformly dark head, do NOT add a white face mask. If the reference shows solid wings, do NOT add white wingbars. If the reference has no crest, do NOT add a crest.
- For close-relative species (multiple goldfinch, multiple jay, multiple sparrow species in the library), render the diagnostic differences clearly so the species are visibly distinguishable from each other.

### Feet

- BOTH FEET visible at the bottom of the body.
- Songbird feet are SMALL relative to the body. Tarsi (legs below the feathers) are roughly 10-15% of body height for finches/sparrows/warblers/chickadees, 15-20% for jays/thrushes/mockingbirds. For larger birds (ducks, hawks, owls), match the proportion in the reference photo - typically still under 25%.
- Draw slim tarsi, small delicate toes. Do NOT exaggerate feet or claws; the bird is not a chicken or a crab.
- Match foot proportion to the attached reference photo.

### Pose

- PERCHED (pose 1): one wing folded against the body, the other tucked behind. Both feet visible at the bottom, toes curled gently forward as if grasping a thin perch - but the perch itself is NOT drawn. The bird floats in space, posture suggesting it's perched.
- IN FLIGHT (pose 2): both wings fully extended in a natural flapping position. Legs and feet either (a) tucked tight against the belly with toes folded out of sight, or (b) extended straight back along the line of the tail. Do NOT dangle the feet below the body with toes splayed.

### Output

Render at high resolution with an OPAQUE background.

Do NOT use transparency or an alpha background.

The background must be pure solid magenta (#FF00FF), completely uniform from edge to edge.

The bird itself must retain its intended painted appearance and natural color variation.

Do not cast any shadow onto the background. No paper texture, no caption, no border, no additional objects.
