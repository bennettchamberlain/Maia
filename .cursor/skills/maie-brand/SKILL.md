---
name: maie-brand
description: >-
  Maie brand, motion, and shadcn Flutter rules. Use when designing or
  changing Maie UI, animation, the talk cloud, the world ring, color,
  or empty states. Maie is a visualization of intelligence. Chrome stays
  shadcn. The mark is light line work and a slow point cloud.
---

# Maie

Maie is a visualization of intelligence. The person should see the mind as an instrument, not a character with a face.

Chrome is shadcn. Black, white, hairline borders, the existing type. Do not restyle buttons, lists, nav, or pages into the mark. The mark shows up only where intelligence is becoming visible.

## Palette

Ink and paper come from `ShadTheme.colorScheme` (`foreground`, `background`, `border`, `mutedForeground`).

The only chromatic colors are Felipe Pantone's diffraction sunset, warm on one side and cold on the other. Use them on the mark, never as UI fills.

- `#08040E` night
- `#4A0C56` violet
- `#FF2A6A` magenta
- `#FF5C24` orange
- `#FFBA40` gold
- `#FFF4E0` pale
- `#FFFFFF` day

## Drawing

Lines are 1px. Dots are 1 to 2px. No fills, no glossy orbs, no bouncing bars, no drop shadows on the mark. A circle, if one is needed, is a tick ring like a scientific plate.

The talk mark is that ring. Grains sit on the circle, with a few just off it. It turns slowly. It is not an arc, not a sphere, and not a face.

Rest moves slowly. A cloud tumbles over many seconds. An event is a fast spike that eases back. Attack is sharp. Decay is short.

Mimic a signal. Do not analyze audio or run a transform. A few sines at different rates, raised to a high power, make sparse spikes that read as amplitude and frequency.

One mark at a time. Do not decorate empty states, toasts, or navigation.

## Where it goes

Use these when that surface is actually being built. Leave the rest of the app alone until then.

- Talk, on: `MaieCloud` drifts slowly above the composer. While speaking, points kick off the arch. Quiet points stay ink. Spiking points take the sunset.
- Thinking, a tool call: the same cloud, no spikes, one meridian sweeping.
- A finished grant: the world ring. Black and white instrument, sunset only on the evening limb. See `server/maie/lib/src/one/done_page.html`.
- Streaming prose: do not animate the letters. A 1px rule may grow.

Reference implementation: `app/lib/ui/maie_cloud.dart`.
