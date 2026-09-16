# Porting the setup editor onto Lich's WebUI

How PR [elanthia-online/eohunter#117][pr117] sheds its own WEBrick server and
hand-written JS client and renders through Lich's native WebUI instead.

Written 2026-09-16. Assumes the WebUI is merged and present in lich-5 at
contract **2.15.0** — `Lich::API.webui_*` is simply available. Every claim below
was reproduced against `eohunter@pr117` (`134b9de`) and `lich-5@feat/webui-port`.

[pr117]: https://github.com/elanthia-online/eohunter/pull/117

## Verdict

**The port is viable and most of it works today.** The map editor — the piece
most likely to have forced a new node type — runs end-to-end on the unmodified
contract, with real GSIV data, at 45 ms.

Three things are worth knowing before starting:

| | |
|---|---|
| **One contract change is load-bearing** | `region` layers cannot be drawn, so room roles have no colour. Everything else has a workaround. |
| **One trap is operational, not cosmetic** | Starting the shared service from a script thread kills it on `;kill`, for every other script too. |
| **PR 117 is a draft prototype** | It self-describes as a "discussion prototype … not ready for formal review or merge". This port is a rework of that draft, not a merge-readiness pass over it. |

## Getting at it

`Lich::WebUI` is the script-facing surface:

```ruby
Lich::WebUI.page(owner:, id:, title:, props:, on:) { |b| ... }
Lich::WebUI.open(page:)          # or launch_url(page:)
Lich::WebUI.refresh(page)
Lich::WebUI.terminate_owner(owner)
Lich::WebUI.service.register_files(alias, dir, owner:, script_root:)
Lich::WebUI::Contract::VERSION   # => "2.15.1"
```

There was a `lib/api/webui.rb` wrapper of ten one-line delegations. It was
deleted as dead code (lich-5 `29f28fd6`) on the grounds that "scripts reach
the same functions through `Lich::WebUI` directly" -- which is what this port
does. Worth knowing if you read an older draft of this document.

Nothing in Lich requires the WebUI at boot, and `--webui-dev` gates only the
login launcher and `ScriptScope` (`lib/main/main.rb:197-222`) -- not the
library. `lib/webui.rb` loads standalone with no Lich boot state and no GTK,
so a plain

```ruby
require File.join(LIB_DIR, 'webui.rb')
```

is enough, in any session, flag or no flag. Verified by running it.

## The one real trap: thread groups

Every script gets its own `ThreadGroup` (`lib/common/script.rb:1900`), killed
when the script dies. `Server#start` creates its accept loop with a bare
`Thread.new` (`lib/webui/server.rb:53`). The WebUI service is **process-wide and
shared**.

Put those together: if eohunter calls `service.start` from its own script
thread, the listener joins eohunter's thread group, and `;kill eohunter-setup`
takes down the WebUI for *every* script using it. lich-5 already knows this
failure mode — `server.rb:68-69` reads:

> A listener whose accept loop died (killed thread) still holds the port;
> release it before binding again.

The core launcher never hits it because it starts the service from the main
thread (`lib/common/webui_launcher.rb:98`).

**Requirements:**

- Start the service from `ThreadGroup::Default`, or attach to an
  already-running one.
- On exit call `Lich::API.webui_terminate_owner(self)` — **never**
  `service.stop`. `terminate_owner` (`runtime.rb:154-167`) shuts down that
  owner's dispatcher, sends `page_closed(reason: :owner)` to viewers,
  unregisters its pages, and leaves the service up for everyone else.

## What the port deletes

| File | Fate |
|---|---|
| `setup/server.rb` (113 lines) | **Deleted.** Token, Origin, Host, CSP, `MAX_BODY`, the static-asset allowlist — all replaced by Lich's loopback server (launch token, HttpOnly session cookie, Origin allowlist, CSP). |
| `setup/assets/*` (2,563 lines JS/CSS/HTML) | **Deleted.** The UI becomes a Ruby render block. |
| `setup/map_images.rb` | **Deleted.** Replaced by `register_files` (below). |
| `App#call`'s JSON dispatcher | **Deleted as a dispatcher.** Its 14 actions become event-handler method bodies; none of the logic is lost. |
| `ASSETS` bundling in `tools/build_setup.rb` | **Deleted.** No hand-written assets remain to bundle; the existing `append_marked` source-concatenation still builds the one-file script. |
| `spec/eohunter/setup/server_spec.rb` | **Deleted** with the server it tests. |

## What survives untouched

All nine domain modules are transport-independent — verified by grepping each
for WEBrick/HTTP/request coupling (zero real hits):

`store.rb` · `schema.rb` · `composition.rb` · `geography.rb` · `hazards.rb` ·
`area_catalog.rb` · `area_catalog_data.rb` · `area_zones.rb` ·
`society_abilities.rb`

`Store` keeps its own revision/`Conflict` optimistic-concurrency model, which is
still the right thing — a second viewer on the same page is now *more* likely,
not less.

Two assets make the port much smaller than its line count suggests:

- **`Schema#fields` is already data-driven** (`schema.rb:165-183`). Each of ~129
  fields emits `key`, `type`, `options`, `label`, `help`, `page`, `editor`,
  `advanced`, `units`. A generic Ruby renderer loops over these; the settings UI
  ports wholesale rather than field-by-field. Only `cleaner == :structured`
  fields need bespoke editors.
- **The eight stale-request counters disappear.** `app.js` hand-rolls
  `readRequest`, `resolveRequest`, `areaRequest`, `footprintRequest`,
  `profileMapRequest`, `profileRoomRequest`, `documentId`,
  `validationGeneration` to discard out-of-order responses. The runtime stamps
  every render with a monotonic generation and refuses mismatched events
  (`runtime.rb:208,217`). Delete them all.

## The map editor works today

Built the worst case from the real map database
(`data/GSIV/map-1788922100.json`: 36,838 rooms, 21,838 with `image_coords`,
279 sheets):

```
sheet wl-gates-1264234799.png = 495 rooms  (the busiest in the game)
1 image + 495 regions          = 496 layers      cap 512
render                         = 45.5 ms / 60 KB
surface_activate primary       -> room-213
surface_activate secondary     -> room-213
```

That is PR 117's "left-click changes membership, right-click changes role",
working on the unmodified contract. Native `image_coords` (`[524,415,534,425]`)
maps 1:1 onto a region's `x1/y1/x2/y2` — no new data, no transformation.

Map images serve straight from `MAP_DIR`, because `script_root` is
caller-supplied (`file_service.rb:88-92`):

```ruby
service.register_files('eohunter-maps', MAP_DIR, owner: self, script_root: MAP_DIR)
# => "/files/eohunter-maps/"
```

This is strictly better than PR 117's base64 data URLs, which round-trip a 4 MB
image through JSON — and which could not work anyway, since composite `src` is
`body_text`, capped at 8,192 bytes (`contract.rb:33,507`).

## The one contract change that matters

**`region` layers cannot be drawn.** The client is explicit
(`assets/app.js:765`):

```js
// A region is a hit area, not something drawn.
```

PR 117's map shows five room roles at a glance — hunting, boundary, starting
room, field rest, town rest — each with its own colour. With regions invisible,
each marked room needs a second `label` layer, and that is what breaks the cap.

Measured across all 279 sheets:

| Layering | Sheets over the 512 cap |
|---|---|
| 1 image + 1 region per room (hit only) | **0 of 279** |
| 1 image + region + label per room | **18 of 279** (worst: 991 layers) |

So the cap only bites *because* regions cannot be drawn. **Fix the region, and
the cap raise becomes unnecessary** — this inverts the prior audit's priority,
which listed the cap as the blocker and the tone as "Major".

I prototyped the fix. Two lines in `contract.rb`, mirroring what `bar` layers
already do at `contract.rb:516`:

```ruby
label: property(SHORT), activates: property(BOOL, default: false),
tone: property(union(enum(*TONES), RGBA))
```

Then all 495 rooms carry distinct RGBA role colours in **one layer each**:

```
layers=496  ALL FIVE ROLES COLORED, ONE LAYER PER ROOM
render: 57.3 ms / 63 KB
sample region tone: {r: 46, g: 160, b: 67, a: 0.45}
```

Five roles exceed the four `TONES`, so the RGBA arm of the union is required,
not optional. Client side it is ~3 lines in the `region` branch
(`app.js:764-776`), mirroring the `bar` branch at `:759-771`, plus a
`.composite-region` background rule (`app.css:250`).

*(The lich-5 working tree was restored to pristine after this experiment.)*

## Performance: better than the prior audit feared

The earlier audit warned of ~20 ms and 122 KB per keystroke. **That does not
happen.** Every input renderer binds the DOM **`change`** event — which fires on
blur/Enter — never `input`: `text_input` (`app.js:649`), `textarea` (`:337`),
`number_input` (`:348`). There is no keystroke traffic to debounce.

Measured on real page shapes:

| Page | Render | Wire | Components |
|---|---|---|---|
| Full settings UI: 10 tabs, ~130 fields, each with help + provenance | **17.4 ms** | 88 KB | 532 / 20,000 |
| Worst-case map: 1 image + 495 regions | **45.5 ms** | 60 KB | 2 |

Component budget is a non-issue at 2.7%. And `tabs.selected` is viewer-scoped
(`contract.rb:261`), so switching tabs never round-trips to Ruby at all.

Two notes for whoever writes the render block: `tabs.selected` is an **index**,
not a name, and `tabs` children need an explicit `slot:` matching `names`.

## Known fidelity losses

Honest list. None blocks the port; all are visible to a user.

1. **Search is on Enter/blur, not per-keystroke — the one loss with no
   workaround.** `text_input` has `search: true`, but that only selects the HTML
   input *type* (`app.js:647`) — a rounded box with a clear "x". It wires no
   extra event. Of the client's 54 `addEventListener` calls, **not one is for
   `input`**; the only matches for that string are the two `node("input")`
   constructions at `:171` and `:626`. So `search:` is cosmetic, and PR 117's
   substring filter over `state.boot.fields` (`app.js:1909-1921`) becomes
   filter-on-Enter.

   The upstream fix is small: a debounced `input` listener on the `text_input`
   renderer, gated on `props.search` so only search-flagged fields pay the
   full-tree render cost. Worth proposing alongside item 2 below.
2. **`select` ignores `disabled`.** It bypasses the `input()` helper — the only
   place `control.disabled` is set (`app.js:170-178`) — so a disabled select
   renders fully interactive. **One-line fix**, worth sending upstream.
3. **No `optgroup`, and no per-option `disabled`.** `OPTION` is a flat
   `{value, label}` (`contract.rb:104-107`). PR 117 uses `optgroup` four times,
   including the combat condition builder. Use prefixed flat labels or chained
   selects.
4. **The routine editor cannot be a `table`.** Cells are plain text —
   `tr.append(node("td", null, row.cells[column.key]))` (`app.js:707`) sets
   `textContent`, so a cell can hold no child component. The whole
   `editor`/`cell_edit` surface is contract-only: `grep -c editor` over the
   client returns **0**, though `validator.rb:225-252` accepts
   `text`/`number`/`checkbox`/`select` and `contract.rb:483-485` defines a
   `cell_edit` event. Compose instead from `grid` (`app.js:249`) or
   `columns` (`:361`), which do recurse into real children. No loss in practice:
   PR 117 already composes action rows from stacks and buttons, because cell
   editors were never rich enough for its condition builders.
5. **No `readonly` distinct from `disabled`.** The preserved original-routine
   text, kept visible-but-uneditable, becomes fully inert.
6. **Per-field errors and help are sibling `text` nodes.** No `hint`/`error`
   property on inputs. Costs nodes, not correctness — the 532-component
   measurement above already includes them.
7. **Only `tone-danger` is styled** (`app.css:253`); `positive` and `caution`
   render identically to neutral.
8. **A script cannot ship its own CSS or JS.** `ASSET_ROUTES` (`server.rb:23-27`)
   is a frozen three-entry table — `/`, `/assets/app.js`, `/assets/app.css` —
   fetched by exact key (`:311`), with no wildcard, no directory scan, and no
   per-script registration. `/files/` serves images only (`file_service.rb:10-13`
   allows png/jpg/gif/webp). So PR 117's 255-line `style.css` has nowhere to go:
   all visual design must be expressed through contract properties (`tone`,
   `emphasis`, `align`, `margin`, `width`) and whatever the shared stylesheet
   already provides. This is the single biggest aesthetic difference between the
   prototype and the port, and it is by design — the contract is the styling
   surface.

## Two footguns to route around

- **Don't name component keys `entry-*`.** The shared stylesheet carries six
  `[data-cid*="group:entry-"]` rules with `!important` (`app.css:259-276`) that
  belong to the launcher's login list. They match on substring, so any page
  using those keys inherits launcher layout. PR 117's client uses no `entry-`
  keys today, so this is avoidable — but it is a real lich-5 bug worth fixing
  regardless, independent of eohunter.
- **`page(bare: true)`** (`contract.rb:214`, `app.js:184`) opts a script's own
  window out of the launcher's column-stacking media query. Use it.

## Inbound message cap — checked, not a problem

Lich caps inbound client messages at 65,536 bytes
(`protocol.rb:10`, `websocket.rb:11`, `server.rb:274`), against setup's
`MAX_BODY` and `Store::MAX_BYTES` of 1,048,576. This looks alarming and is not:
the cap is on `parse_client_message` — **inbound only** — and under the port the
browser never uploads a document. Ruby owns the draft; the client sends small
events. Outbound renders are uncapped (the 88 KB settings page ships fine).

The only real limits are `textarea.max_length` ≤ 65,536 (`contract.rb:387`) and
`text_input.max_length` ≤ 8,192 (`:365`), both comfortable for every field here.

## Lifecycle

`server.start` / `server.join` / `server.shutdown` becomes:

```ruby
before_dying { Lich::API.webui_terminate_owner(self) }   # never service.stop

page = Lich::API.webui_page(owner: self, id: 'eohunter-setup',
                            title: 'EOHunter · Hunt setup', props: { bare: true },
                            on: { close: ->(e) { done.push(e[:reason]) } }) do |b|
  render_setup(b, state)
end

start_service_from_default_thread_group
Lich::API.webui_open(page: page) || Lich::Messaging.msg('info', url)
done.pop                                                  # replaces server.join
```

`PAGE_LIFECYCLE_EVENTS` (`contract.rb:595-598`) gives `close`
(`reason: :user | :owner | :timeout`), `attach` and `detach`.

**Chrome is not a hard requirement.** `BrowserLauncher` needs Chrome or Edge
only for the app-mode window (`browser_launcher.rb:50-56`); `launch_url` is an
ordinary tokenized loopback URL that any browser opens. PR 117 already prints
its URL — keep doing that when the launcher returns false.

## Event handlers run on a dispatcher thread

One dispatcher thread per **owner**. A raise is caught and logged and the thread
survives (`dispatcher.rb:118-122`), but a *blocking* callback stalls every other
callback for that owner, and `Future#await` from inside one raises
`ReentryError` by design. Keep handlers short: mutate state, call
`webui_refresh`, return. Long work (area resolution, map geometry) belongs on a
worker thread that refreshes when it finishes.

`send_render` ships the **entire tree** every refresh — there is no diffing
(`runtime.rb:302-314`). At 17–45 ms per render that is fine; it is simply worth
knowing that a refresh is not free.

**Delete confirmations must not block.** `Future#await` raises
`ReentryError` the moment it is called from a dispatcher thread
(`future.rb:57-60`), which is exactly where a Delete button's handler runs. Use
the non-blocking `.then` form instead. A `Future::Result` is
`Data.define(:button, :reason)` (`future.rb:9`); a real press resolves with the
button id and **`reason: nil`** (`modal_coordinator.rb:42`), while `:timeout`
and `:no_viewer` carry a reason instead. Note `:no_viewer` can resolve *with* a
button — it substitutes `default_button` (`:79`) — so test the reason, not just
the button:

```ruby
Lich::API.webui_modal(...).then do |result|
  next unless result.reason.nil? && result.button == 'delete'
  store.delete_document(kind, name, expected_revision: revision)
  refresh!
end
```

That `:no_viewer` substitution is the one to be careful with: a `default_button`
of `delete` would auto-confirm a deletion with nobody watching.

Also note modal buttons take `variant: default|primary|danger`
(`contract.rb:110-114`) — not `tone:`, which is what every other node uses.

## Where the port stands

Done, on `feat/webui-setup-port`:

1. **Lifecycle spine** -- service started from `ThreadGroup::Default`,
   page registration, `terminate_owner` teardown, printed-URL fallback.
2. **Generic settings renderer** -- all 119 schema fields over 12 tabs, with
   help, provenance and per-field errors as sibling `text` nodes. Measured at
   15.9 ms / 116 KB / 513 components.
3. **Landing page** -- lists saved hunts and loads one. Revision checks are
   wired through `Store`, so a conflicting save is reported, not silently won.
4. **The build** -- `rake build` writes `dist/eohunter-setup.lic`, asset
   bundling gone.

Still to do:

5. **Document management** -- rename, hide/show, set-active, and delete with a
   `dialog` confirmation (see the non-blocking `.then` note above).
6. **Map editor** -- `register_files`, composite + regions, left/right click.
   Proven to work; not yet wired into the page. Ships colourless until the
   region-tone change lands.
7. **Bespoke editors** -- routine, injury policy, ordered lists, and the
   `structured` fields, which currently fall back to a YAML textarea.
8. **The guided five-step wizard**, which the tabbed editor does not replace.

None of 5-8 needs anything from lich-5. Only the region colour does.

## What to send upstream to lich-5

Small, additive, and useful beyond eohunter:

1. **`tone` on `region` layers** — `union(enum(*TONES), RGBA)`, plus the client
   class and CSS. The only change this port genuinely needs.
2. **`select` honours `disabled`** — one line.
3. **A debounced `input` listener on `text_input`, gated on `props.search`** —
   restores live filtering (loss 1) without making every field chatty.
4. **Move the `[data-cid*="group:entry-"]` rules out of the shared stylesheet** —
   a latent collision for any second consumer.

Deliberately *not* requested: the `BOUNDS[:collection]` raise. With coloured
regions, zero of 279 sheets exceed it.

Optional, lower value: `scope: :viewer` on `composite.scale`. PR 117 does
Fit/2×/3×/4× as a local CSS class change (`app.js:1810-1813`), instant and
per-browser; under the WebUI each zoom step is one round-trip and a full map
re-render (~45 ms), and one viewer's zoom changes it for all of them. Adjacent
`scroll_to` is already viewer-scoped (`contract.rb:536`), so this is a scope
change, not new rendering. Also optional: `hint`/`error` on inputs; `group` on
`OPTION`.
