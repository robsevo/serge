---
name: frontend-design
description: Design direction for building distinctive, intentional UI — aesthetic choices, typography, palette, layout, copy — so new or reshaped interfaces read as designed for THIS brief, not templated AI defaults. Use BEFORE writing frontend code, whenever a page, component, landing page, dashboard, app UI, or redesign is being planned or built — even if the user never says the word "design".
whenToUse: Use whenever user-facing UI is about to be written or reshaped — new pages/components/apps, landing pages, dashboards, redesigns, "make it look better/professional/modern", styling or theming work. Load it BEFORE code is written, at the design/planning step. Pair with the frontend agent (engineering/motion/a11y); this skill owns visual identity and design direction. Not for pure logic/backend work.
---

# Frontend design — a point of view, not a template

Approach this as the design lead at a small studio known for giving every
client a visual identity that could not be mistaken for anyone else's. The
client has already rejected templated proposals and is paying for a
distinctive point of view: make deliberate, opinionated choices about palette,
typography, and layout that are specific to this brief, and take one real
aesthetic risk you can justify.

## Ground it in the subject

If the brief doesn't pin down what the product or subject is, pin it yourself
before designing: name one concrete subject, its audience, and the page's
single job, and state your choice. The subject's own world — its materials,
instruments, artifacts, and vernacular — is where distinctive choices come
from. Build with the brief's real content throughout.

## Know the AI-slop attractors — and avoid them

AI-generated design clusters around three looks: (1) warm cream background
(near #F4F1EA) + high-contrast serif display + terracotta accent; (2)
near-black background + one acid-green or vermilion accent; (3) broadsheet
layout with hairline rules, zero border-radius, dense newspaper columns.
Plus the older tells: centered everything, purple gradients, uniform rounded
corners, Inter for everything. All are legitimate for some briefs, but they
are defaults, not choices. Where the brief pins a direction, follow it
exactly — the brief's words always win, even when it asks for one of these
looks. Where an axis is free, don't spend that freedom on a default.

## Design principles

- **The hero is a thesis.** Open with the most characteristic thing in the
  subject's world — headline, image, animation, live demo, interactive
  moment. "Big number + small label + gradient accent" is the template
  answer; use it only if it's truly best.
- **Typography carries the personality.** Pair display and body faces
  deliberately — not the families you'd reach for on any other project. Set
  a real type scale with intentional weights, widths, spacing. Make the type
  treatment itself memorable, not a neutral delivery vehicle.
- **Structure is information.** Numbering, eyebrows, dividers, labels must
  encode something true about the content. Numbered markers (01/02/03) only
  belong on content that actually is a sequence.
- **Motion is deliberate.** One orchestrated moment lands harder than
  scattered effects; sometimes none is right — excess animation reads as
  AI-generated. (The frontend agent owns motion engineering: compositor-only
  properties, reduced-motion, interruptibility.)
- **Match complexity to the vision.** Maximalist directions need elaborate
  execution; minimal directions need precision in spacing, type, detail.
  Elegance is executing the chosen vision well.

## Process: brainstorm → plan → critique → build → critique again

Work in two passes. First, a compact design plan from the brief — a token
system:

- **Color**: the palette as 4-6 named hex values.
- **Type**: typefaces for 2+ roles (characterful display used with
  restraint, complementary body, utility face for captions/data if needed).
- **Layout**: the concept in one-sentence prose + ASCII wireframes to
  compare options.
- **Signature**: the single element this page will be remembered by.

Then review the plan against the brief before building: if any part reads
like the generic default you'd produce for any similar page, revise it and
say what you changed and why. Only then write code, following the revised
plan exactly and deriving every color and type decision from it.

When writing CSS, watch selector specificity — type-based selectors
(`.section`) and element-based ones cancel each other out, most often on
section paddings/margins.

Do the iteration in your head; show the user work you already believe in.

## Restraint and self-critique

Spend your boldness in one place. Let the signature element be the one
memorable thing; keep everything around it quiet and disciplined; cut any
decoration that doesn't serve the brief. Not taking a risk is also a risk.
Build to a quality floor without announcing it: responsive down to mobile,
visible keyboard focus, reduced motion respected. Critique your own work as
you build — screenshot it if the environment allows; a picture is worth
1000 tokens. Chanel's advice: before leaving the house, look in the mirror
and remove one accessory.

## Copy is design material

Words exist to make the design easier to understand and use. Write from the
user's side of the screen: name things by what people control and recognize
("notifications", not "webhook config"). Active voice; a control says
exactly what happens ("Save changes", not "Submit"); an action keeps its
name through the whole flow ("Publish" → toast "Published"). Errors explain
what went wrong and how to fix it — never apologize, never vague. An empty
screen is an invitation to act. Plain verbs, sentence case, no filler; one
job per element — a label labels, an example demonstrates, nothing quietly
does double duty.

---
*Adapted from [anthropics/skills](https://github.com/anthropics/skills)
`frontend-design` (Apache-2.0 — see LICENSE.txt). Reworked for serge: house
frontmatter, frontend-agent split (it owns engineering; this owns direction).*
