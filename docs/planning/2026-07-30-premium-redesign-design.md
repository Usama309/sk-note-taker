# SK Note Taker Premium Redesign: Design

Status: DRAFT, pending user approval.
Decisions locked with Usama: evolve the charcoal+mint brand (bolder, logo stays the anchor),
full premium pass on every screen, real dark mode, UI sounds on by default with a Settings toggle.

Grounding: a 6-agent survey of every view file found ~120 styling sites bypassing Theme tokens,
~60 dark-mode breakages (worst: `.preferredColorScheme(.light)` forced on both scenes), a
near-greenfield motion story (one 0.18s easeInOut constant duplicated inline), 13 spinner sites,
zero skeletons (meeting detail content pops in with no loading state), and shortcuts limited to
Cmd+N / Cmd+E / Cmd+Shift+D plus Return in sheets. Notes autosave already exists (no save button).

## 1. Theme 2.0 (foundation everything else sits on)

### Palette: bolder, still ours
- Anchors stay: charcoal `#1F242A` + mint `#78C6A3` (the logo's colors).
- Bolder accent moments: a `heroGradient` (deep charcoal into mint-tinged charcoal with a mint
  edge-glow) for the home CTA and hero surfaces; `mintGradient` for accent fills, hover glows,
  and focus rings. Stronger contrast between bg / surface / card so screens read layered.
- New semantic tokens (killing every raw color literal the survey found):
  `Theme.recording` (brand-tuned red), `Theme.star` (tuned yellow), `Theme.selection`,
  `Theme.dropTarget`, `Theme.folderPalette` (6 brand-derived hues), `Theme.chip(_:)` opacities.
  Raw `.green/.red/.orange` sites move to existing `Theme.success/error/warning`.
- Legacy aliases (`indigo`, `teal`, `ink`) get migrated at call sites and deleted.

### Dark mode: real, not best-effort
- Remove both `.preferredColorScheme(.light)` forces (SKNoteTakerApp.swift:36, :70).
- Surfaces already tokenized (`bg #0F1115`, `surface #171A20`, `card #1F232B`, `border #2D333C`);
  the work is migrating the ~60 flagged sites onto them (system materials at magic opacities,
  `.textBackgroundColor`, `.white` on gradients, 0.05-0.18 tint ladders that vanish on charcoal).
- Speaker colors get a dark variant palette (the light palette is documented as light-only;
  `speakerColor(key)` becomes appearance-aware via Color(light:dark:)).
- Elevation model: light mode keeps soft shadows; dark mode switches to hairline borders plus a
  slightly lighter surface (shadows are invisible on near-black).
- The plusLighter radial hero glow gets per-scheme tuning.

### Type: simple, two families, zero stragglers
- Keep Plus Jakarta Sans (display/headings) + Inter (everything else). No new fonts.
- Add `skDisplay` (Jakarta 32 bold) for the hero; migrate all ~40 `.system(size:)` stragglers
  onto the ramp (worst offenders: home headline, detail title field, the brand wordmark itself).

### Motion system: one vocabulary, used everywhere
- `Theme.Motion` tokens: `snap` (0.15 easeOut: hovers, toggles), `standard` (0.22 easeInOut:
  tab/content changes), `spring` (response 0.35, damping 0.75: cards, buttons, palette),
  `gentle` (0.4: hero entrances). All withAnimation call sites use tokens, never inline curves.
- Respects Reduce Motion (accessibilityDisplayShouldReduceMotion: crossfades only).
- Signature moves: staggered fade-up entrance on home cards; matchedGeometryEffect underline on
  the detail tab bar; spring press-scale on primary buttons (shared PressableButtonStyle);
  hover lift (+shadow) on list rows and cards; record button gains a slow breathing pulse while
  recording; live transcript segments slide-in; copy buttons morph to a success check.
- Fix the existing bug where the live suggestion card declares a .transition with no enclosing
  withAnimation (it never animates).

## 2. Command palette (Cmd+K)
- `CommandPaletteView`: a floating overlay panel (ZStack over the window root, not a sheet, so it
  opens instantly), Spotlight-style: search field + ranked results, arrow/Return/Escape keys.
- `CommandRegistry`: `Command { id, title, icon, keywords, shortcutHint, isAvailable, run }`.
  Sources: app actions (Start/End meeting, New project, Screen recording, Open Assistant,
  Connect calendar, Settings panes, Export project, Replay onboarding), navigation (All/Starred/
  Upcoming/each project), content jumps (meetings by fuzzy title match, upcoming events with
  Join / Start notes). Fuzzy subsequence scoring with recents boost (persisted, small).
- Availability is contextual (End Meeting only while recording, etc).

## 3. Keyboard-first navigation
- Global: Cmd+K palette, Cmd+N new meeting, Cmd+E end, Cmd+F focus search, Cmd+1/2/3 sidebar
  filters, Cmd+, settings, Escape closes overlays.
- Detail: Space play/pause, Left/Right seek 5s, Cmd+Shift+C copy transcript, Cmd+1/2/3 tabs
  while focused (tab bar also shows hints on hover).
- Lists stay natively arrow-navigable; palette carries visible shortcut hints so the map is
  discoverable. Menu bar items get their shortcuts listed too.

## 4. Loading: skeletons, not spinners
- `SkeletonView` component: rounded placeholder blocks with a soft moving shimmer (masked
  linear gradient; static fill under Reduce Motion), in list-row, card, and text-line shapes.
- Applied where the survey found pop-in or spinners: meeting detail initial load (transcript,
  summary, action items rail), ProjectMemory sheet full-screen gate, ScreenSourceSheet window
  list, Upcoming refresh, screen-recording card. Button-inline busy states (send/thinking) stay
  as small spinners, restyled to the brand.

## 5. Infinite scrolling for note history
- Meeting list renders a window (first 30) and extends by 30 when the last row appears
  (onAppear sentinel). With today's meeting counts this is future-proofing; it is cheap and
  removes the full-array render cost as history grows. Search still filters the full set.
- Transcript already uses LazyVStack (fine as is).

## 6. Sounds: tiny, soft, optional
- `SoundManager` (NSSound, volume ~0.18, all under 250ms, synthesized in-repo, no copyright):
  `noteSaved` (soft tick), `recordingStarted` (gentle rising two-tone), `recordingStopped`
  (falling two-tone).
- Trigger rules: recording start/stop on session transitions. Saved plays ONLY for deliberate
  save moments (speaker names saved, project memory saved, import finished, export done).
  It NEVER plays on the notes TextEditor autosave path, which fires per keystroke: that is the
  "never during typing" rule enforced structurally, not by debounce.
- `AppSettings.uiSounds` (default true) + a Settings toggle under General.

## 7. Screen-by-screen (survey-driven)
- Home: staggered entrance, bolder hero CTA with mint glow, Upcoming card on Theme.card,
  SetupHint onto warning tokens.
- Sidebar: tokenized selection/hover with hover lift, brand folder palette, badge restyle.
- Meeting list: refined rows (title weight, meta line, speaker chips dark-safe), LIVE badge on
  Theme.recording, hover reveal actions, skeletons, windowed scrolling.
- Meeting detail: title on ramp, animated tab underline, spring play button, animated waveform
  progress, skeleton first-load, media-key shortcuts, copy morphs.
- Live meeting: breathing record indicator, suggestion card transition fixed, bubble tints
  dark-safe, meters kept.
- Sheets/Settings: all surfaces onto tokens, semantic colors replace raw green/red/orange,
  consistent dialog radius/materials.
- Onboarding/tips: already the motion pattern-setter; tokenize stragglers so it matches.
- Menu bar: keep color logo (it carries contrast on both menu bar appearances); verify in dark.

## 8. Architecture / new files
- `Theme.swift` grows: Motion tokens, semantic tokens, dark speaker palette (single source).
- New: `Components/SkeletonView.swift`, `Components/ButtonStyles.swift` (Pressable + HoverLift),
  `CommandPalette/CommandRegistry.swift`, `CommandPalette/CommandPaletteView.swift`,
  `SoundManager.swift` (+ 3 tiny bundled audio assets in Resources/Sounds).
- `AppSettings`: + `uiSounds: Bool = true`. No other model changes. No new dependencies.

## 9. Phases (each verifiable in the running app)
1. Theme 2.0 foundation: dark mode unlock + token migration + motion tokens. Verify: screenshot
   every screen in both modes.
2. Command palette + keyboard map.
3. Skeletons + loading states + windowed list.
4. Sounds (+ Settings toggle).
5. Motion polish pass per screen + full QA sweep (both modes), tests green throughout.

## Risks
- Dark mode is the big one: flipping it on exposes every missed site. Mitigation: the survey's
  file:line inventory is the migration checklist; phase 1 ends with a both-modes screenshot QA
  of every screen before anything else lands.
- Keyboard shortcuts colliding with system/text-field focus: media keys only bind when the
  detail pane has focus and no text field is active.
- Sounds in meetings: start/stop cues are the point, but volumes stay very low and the toggle
  is one click.
