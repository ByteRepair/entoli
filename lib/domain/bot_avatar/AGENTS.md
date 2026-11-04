# Bot Avatars

An agent's face can be a Bot Avatar instead of a photo: an object with two
eyes, drawn live with implied volume, that idles, thinks and is happy. The
format and the engine are [Open Bot Avatar](https://github.com/DominikScholz/open-bot-avatar)'s,
MIT, ported to Dart here; its licence is an asset
(`assets/bot_avatars/LICENSE.txt`) read into the licence page by
`registerBotAvatarLicence`.

## The spec

A definition is geometry only — one SVG path in a 0..100 box and where the
eye pair sits — held to the upstream contract (`docs/avatar-contract.md`,
version 1) by `BotAvatarDefinition.validate`, which is the only way to get a
`BotAvatarDefinition`: a held one is normalised, its path rebuilt from
numbers. `BotAvatarSpec` is what an agent wears: a definition plus the
colours, `{"definition": …, "color": "#rrggbb"}` with an optional
`eyeColor`. The definition rides inside the spec rather than by id, so an
agent keeps its shape when the import it came from is deleted, and a spec
copied to another device needs nothing else.

An agent's spec is `<name>.avatar.json` beside its `.md`, the photo's
sibling (`agentAvatarPath`). The two are one face held two ways: a save
writes one and takes the other away, a rename moves both, a delete removes
both, and where a rung somehow holds both the avatar wins. `AgentFace`
(`lib/domain/agent_face.dart`) is the sealed answer the reader gives —
`AgentPhoto` or `AgentBot` — and `AgentPictureImage` draws either.

## The presets, and the user's

The presets are `assets/bot_avatars/presets.json`: one spec per upstream
starter and gallery entry, in its upstream colour, read through
`BotAvatarSpec.fromJson` like any other spec — a preset that fails the
contract is skipped with a line. It was generated from the upstream repo at
`dadfac3e` (`packages/core/src/examples.ts` and `gallery/*.json` with
`gallery/colors.json`); refresh it the same way rather than by hand.

What the user imports is `<dataDir>/bot_avatars.json`, a list of
definitions (`BotAvatarLibrary`, served by `importedBotAvatarsProvider`).
App-wide, not per project, since any project's agent may wear one; an
import of an id already there replaces it. An import's own colour is a
bright palette colour hashed from its id (`BotPalette.ownColour`), as the
reference does.

## The engine

The files map one to one onto upstream's `packages/core/src`:

- `path.dart` — the restricted SVG path parser and flattener (`path.ts`).
- `definition.dart` — the validator, body analysis and eye fit
  (`validate.ts`).
- `contour.dart` — marching squares and loop simplification (`contour.ts`).
- `volume.dart` — the implied volume (`volume.ts`): each filled subpath is a
  part, inflated or revolved, cut once into z-slices and x-slices.
- `pose.dart` — the pose model, mood blending, pointer follow and the
  animator (`motion.ts`, `mood.ts`, `follow.ts`, `animator.ts`).
- `frame.dart` — `avatarFrame` from `render.ts`: one frame as projected
  slices and eyes, back to front. `PreparedBotAvatar` caches the volume by
  geometry and depth, since building it is the expensive part.

What is not ported: the SVG and CSS-3D renderers (Flutter paints the frame
itself), the seam and face-room checks only the upstream strict validator
runs, and the slice-thinning that exists for CSS layer counts. A slice
keeps its polygons instead of a `d` string; the painter builds one
`ui.Path` per slice the first time it is drawn (an `Expando` on the slice).
Arithmetic follows the reference line for line — the 32-bit hash and noise
included — so a pose is the reference's pose; it has not been checked frame
for frame against the TypeScript, only for shape (every preset draws a body
and two eyes in every mood; see `test/domain/bot_avatar_test.dart`).

## On screen

`BotAvatarView` (`lib/ui/bot_avatar/`) is a `CustomPainter` over a
`ValueNotifier<BotAvatarFrame>`: a still, or live on a ticker. Lists draw
stills — a ticker a row is not worth it — and the places that show one face
animate it: the agent editor, the context page, and a member's reply while
it is being written, which thinks. Reduce-motion holds the calm pose.

The editor (`BotAvatarEditorPage`) is opened from the agent editor's picture
menu ("Use Bot Avatar" beside "Upload photo"). One `Flex` lays it out: the
preview over the controls on a portrait screen, beside them on a landscape
one. Bots is the grid of presets and imports over the colour bar (palette,
custom, reset); Import takes pasted JSON — fenced, in prose, or a list —
through `BotAvatarImport.parse`, and an import leaves the grid by a long
press or right click. The moods on the preview are for looking; a spec
carries no mood.
