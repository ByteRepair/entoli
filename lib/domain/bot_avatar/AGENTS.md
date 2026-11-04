# Bot Avatars

An agent's face can be a Bot Avatar instead of a photo: an object with two
eyes, drawn live with implied volume, that idles, thinks and is happy. The
format and the engine are [Open Bot Avatar](https://github.com/DominikScholz/open-bot-avatar)'s,
MIT, ported to Dart here; its licence is an asset
(`assets/bot_avatars/open-bot-avatar/LICENSE.txt`) read into the licence page by
`registerBotAvatarLicence`.

## The spec

A definition is geometry only — one SVG path in a 0..100 box and where the
eye pair sits — held to the upstream contract (`docs/avatar-contract.md`,
version 1) by `BotAvatarDefinition.validate`, which is the only way to get a
`BotAvatarDefinition`: a held one is normalised, its path rebuilt from
numbers, and it carries the analysis of its path validating it made, so
nothing parses it twice. `BotAvatarSpec` is what an agent wears: a definition
plus its colour, `{"definition": …, "color": "#rrggbb"}`; the eyes are the
reference's near-black ink. The definition rides inside the spec rather than by id, so an
agent keeps its shape when the import it came from is deleted, and a spec
copied to another device needs nothing else.

An agent's spec is `<name>.avatar.json` beside its `.md`, the photo's
sibling (`agentAvatarPath`). The two are one face held two ways: a save
writes one and takes the other away, a rename moves both, a delete removes
both, and where a rung somehow holds both the avatar wins. `AgentFace`
(`lib/domain/agent_face.dart`) is the sealed answer the reader gives —
`AgentPhoto` or `AgentBot` — and `AgentPictureImage` draws either.

The app's own agents wear faces the same way: `<name>.avatar.json` beside
the bundled `<name>.md` under `assets/prompts/projects/<project>/agents/`
(Athena is a marble-white owl, after the owl in the main art; explore is
the orange magnifier, general a violet robot head).
`tool/gen_bundled_skills.dart` embeds them as `bundledAgentFaces`, refusing
one that fails the spec or has no `.md`, and `readAgentPicture` falls back to
one within each rung, below a face on disk there — so a user who gives
explore a picture of their own sees theirs.

## The presets, and the user's

Entoli's own presets are `assets/bot_avatars/presets.json`, empty for now
and offered first. What came from upstream keeps its own directory, with
its licence: `assets/bot_avatars/open-bot-avatar/presets.json`, one spec per upstream
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
  definition, since building it is the expensive part; a part keeps only
  what a frame draws, its height field staying with the build.

What is not ported: the SVG and CSS-3D renderers (Flutter paints the frame
itself), the seam and face-room checks only the upstream strict validator
runs, the slice-thinning that exists for CSS layer counts, and the `depth`
option — every avatar is drawn at the reference's natural depth. A slice
keeps its polygons instead of a `d` string; the painter builds one
`ui.Path` per set of loops the first time it is drawn (an `Expando` on the
loops, which a level's front and back copies share).
Arithmetic follows the reference line for line — the 32-bit hash and noise
included — so a pose is the reference's pose, with one deliberate exception: following a target below tips the face down by 0.45 rad where the reference uses 0.18 both ways, since from the reference's tipped-up resting view that barely left level; it has not been checked frame
for frame against the TypeScript, only for shape (every preset draws a body
and two eyes in every mood; see `test/domain/bot_avatar_test.dart`).

## On screen

`BotAvatarView` (`lib/ui/bot_avatar/`) is a `CustomPainter` over a
`ValueNotifier<BotAvatarFrame>`: a still, or live on a ticker. The agents
list in Settings draws every row live, leaning on the off-screen rule below
to keep only the rows in view moving. A conversation draws stills but for
one: **only the newest message's avatar is live**, thinking while its reply is written and
idling after. One moving avatar per chat rather than one per reply is what
keeps a long conversation from running a ticker a bubble. Where one face is
shown on its own — the agent editor, the context page — it is live. A tap
on a still plays its reaction, live for as long as that lasts. **Under the
platform's reduce-motion setting every avatar is a still**, with no ticker
at all; a turn or a reaction redraws it, and the test harness runs that way
so a page holding an avatar settles.

**A still looks down and to the right** (`stillGaze`) unless it is given a
look of its own: the eyes alone, the body held, since a still is drawn with
reduced motion. That is an idle still — thinking keeps its own look and
happy eyes are arcs with nowhere to point — and the PNG stills of the `@`
menu too. A live avatar wanders and follows as before.

**Every avatar has a hair of outline**, in the theme's `outline` colour, so
a pale one on a pale page — Athena's white owl on the chat's background —
still has a shape. The painter draws the body's silhouette first, in that
colour, into a layer whose `ImageFilter.dilate` grows it by half to one
logical pixel, and the body over it: one edge round the whole shape, none
between its slices (an evenOdd hole, Athena's beak, gets one too). Grown in
pixels rather than stroked per slice, since a slice's projection is a
squash that would stretch a stroke with it.

The `@` menu leads each agent's row with its face, a still (`AgentPicture`
in `CompletionField`). The native shell's menu is SwiftUI, so Flutter draws
those stills to PNG (`agentFacePng`, a photo circled, a Bot Avatar by
`botAvatarPng`) and they ride on `ComposerMenuItem.picture`, drawn while the
composer is up so a menu has them as it opens. A paired device's agents are
its own, with no face here, so neither menu draws one for them.

A live avatar follows the pointer: one global pointer route
(`_PointerWatch`), held while any avatar follows, keeps where the mouse is
anywhere in the window — until it leaves it — and counts touches, each of
which an avatar glances at for 2.5 s on its own clock. A thinking avatar
does not follow; its look is its own.

On top of the mood, a live avatar plays a `BotAnimation`
(`animation.dart`): a mood held for a while, optionally with one eased full
turn, timed on the avatar's own clock, which stands still while it is off
screen — scrolled away mid-animation, it finishes once it is back. A tap where
`reactToTap` (chat, the context page and the agents list) plays `BotAnimation.tapped`: happy
for 5 s, and spinning 15% of the time; a second tap starts it over. A tap on
a still wakes it for the length of the reaction; under reduce-motion there is
none to play.

**Off screen it does nothing.** Flutter does not stop a ticker in a row a
list keeps built past its viewport (the cache extent), but it does skip
painting it. So the painter reports each paint, and a tick that finds the
last frame never drew stops the ticker; that undrawn frame leaves the paint
pending, and the paint that happens when the row comes into view starts it
again. The avatar's clock banks the stopped time, so the motion resumes
where it left off rather than jumping.

The editor (`BotAvatarEditorPage`) is opened from the agent editor's picture
menu ("Use Bot Avatar" beside "Upload photo"), where Use pops the one
chosen; and from "View Bot Avatars" under the agents list as
`BotAvatarEditorPage.browse`, the same page with nothing to choose for —
no Use, a back arrow — for looking through, importing and deleting. One `Flex` lays it out: the
preview over the controls on a portrait screen, beside them on a landscape
one. Bots is the grid of presets and imports over the colour bar (palette,
custom, reset); Import takes pasted JSON — fenced, in prose, or a list —
through `BotAvatarImport.parse`, and points at the `bot-avatar-creator` skill in the Entoli marketplace — an external entry for upstream's avatar design prompt — for a model to design one; and an import leaves the grid by a long
press or right click. The moods on the preview are for looking; a spec
carries no mood.
