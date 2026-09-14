# Mining creature abilities

When a creature does something to you that the engine does not understand,
it keeps doing the wrong thing about it. On 2026-09-13 a branded goliath
diviner cast Mystic Impedance (1708); Rapid Fire went unpreparable for
thirty seconds, and `incant 515` went out 48 times in four seconds because
nothing knew the debuff existed.

The engine now fails a refused prepare instead of counting it as a cast,
so that particular spin cannot recur. But the real repair is data: a
creature file that says what the creature does, so the ability is known
before it lands rather than learned by walking into it.

This guide is how to find that out from a session log and write it down.
The bestiary is Lich's, under `lib/gemstone/creatures`, one Ruby hash per
creature.

## Why it is worth doing

Of 628 creature files, **2** have a populated `abilities:` block, while
**169** record a `messaging.spell_prep` line - a creature visibly casting
something nobody identified. The schema was designed for this and never
filled in. Every entry written is one effect the engine stops rediscovering
the expensive way.

## The tool

`tools/dialog_delta.rb` answers the question "what landed on me here?"

The game pushes a `dialogData` block for Buffs, Debuffs, Active Spells and
Cooldowns whenever one changes, and every entry carries the spell number as
its `progressBar id`, the display name as `text`, and the remaining time as
`time=`:

```xml
<progressBar id='1708' value='50' text="Mystic Impedance" time='00:00:30'/>
```

So the log already contains the number, the name and the duration. The tool
diffs those dialogs across a line and prints what is new.

```
ruby tools/dialog_delta.rb LOG --match "golden runes"
ruby tools/dialog_delta.rb LOG --line 25963
ruby tools/dialog_delta.rb LOG --match "flicks a finger" --context 6 --window 60
```

| Option | Meaning |
|---|---|
| `--match TEXT` | find every line containing TEXT and diff after each |
| `--line N` | diff after line N |
| `--context N` | lines of game text shown around the anchor (default 3) |
| `--window N` | lines after the anchor to watch for new effects (default 400) |

Logs live under `lich-5/logs/<character>/<year>/<month>/`. Use the `.xml`
ones - the `.log` files are the prose without the dialogs, so there is
nothing to diff.

### Reading the output

```
line 25963
    25962: A branded goliath diviner completes his silent incantation and,
           without so much as a glance, flicks a finger at you!
  > 25963: A dizzying array of golden runes surround and suffuse you before
           being absorbed into your body.
  -- appeared --
  Debuffs        id=1708       Mystic Impedance             00:00:30
```

That is the whole identification: spell **1708**, named **Mystic
Impedance**, lasting **30 seconds**, and the two lines above it are the
creature's tell and the effect's onset.

`-- no new dialog effects in window --` is a real answer, not a failure. It
means the ability had no tracked duration: a bolt, a maneuver, an
instantaneous attack. Running `--match "flicks a finger"` across a log found
nine casts by the same diviner - one landing 1708, the others answering
"the very fabric of reality surrounding you fluctuates wildly" with no
dialog entry at all. Those are separate abilities still unidentified.

## The procedure

1. **Find a tell.** Either a `messaging.spell_prep` line already in the
   creature file, or unexplained text from a hunt.
2. **Diff the dialogs.** `--match` that line. Widen `--context` until you
   can see the onset text.
3. **Note the wear-off.** Search for the effect ending; onset and wear-off
   bracket the duration and both belong in `triggers`.
4. **Look up the number.** The wiki dump at `E:\Gemstone\data\wiki_clean`
   has a page per spell. That is where mechanics come from - what it
   blocks, how it scales, whether it is dispellable.
5. **Write the entry**, `nil` for anything not actually observed.

### Never identify by name alone

Two wrong identifications were made during the 1708 investigation, both by
matching an effect to a plausible-sounding spell:

- **Mindwipe**, because it was the one dispellable debuff that sounded like
  amnesia.
- **Corrupt Essence (703)**, because its wiki page says "unable to cast".

Both were wrong, and both survived several minutes of confident reasoning
before the log contradicted them. 703 in particular *looks* right until you
read carefully: it explicitly does **not** block preparing, which is exactly
what the observed message did block.

Confirm the number in the dialog before writing it down. The tool exists so
that this costs one command.

## Writing the entry

Three places in the creature file, all of which the template already
defines.

**`attack_attributes.offensive_spells`** - the spell is part of its kit:

```ruby
offensive_spells: [
  { name: "Mystic Impedance (1708)" }
],
```

**`abilities`** - the structured entry the runtime reads:

```ruby
abilities: [
  {
    id: :mystic_impedance,
    name: "Mystic Impedance (1708)",
    type: :debuff,            # :buff | :debuff | :aura | :proc
    target: :opponent,        # :self | :opponent | :area
    typical_duration_s: 30,
    effects: { blocks_spells_at_or_above: 15 },
    dispellable: nil,
    notes: "Golden runes onset, shows in the Debuffs dialog as " \
           "\"Mystic Impedance\" (id 1708). Blocks the PREPARE of spells " \
           "at or above the threshold; lower spells still prepare and " \
           "cast normally. The threshold is an UPPER BOUND: 515 (level " \
           "15) was observed blocked, so the cutoff is <= 15, but 14 is " \
           "not confirmed safe. Duration 30s observed, matching the " \
           "wiki's creature-cast duration (180s when player-cast). " \
           "dispellable is nil, not false: the 1708 wiki page does not " \
           "mention dispelling and no dispel-side page lists it, so it " \
           "is unknown rather than known-negative."
  }
],
```

That `notes` is long on purpose, and it is the whole example. Every
sentence in it is either something observed and where, or a bound and why
it is only a bound. A reader who finds this creature later can tell
exactly which parts were measured and which are still open - which is not
recoverable from the numbers alone. This entry is live in
`branded_goliath_diviner.rb`; copy its shape, not just its fields.

**`messaging.triggers`** - the lines that start and end it, verbatim from
the log, so the runtime can key on them:

```ruby
triggers: {
  mystic_impedance: [
    "A dizzying array of golden runes surround and suffuse you before being absorbed into your body."
  ],
  mystic_impedance_end: [
    "Golden runes enscribe themselves upon your body, quickly fading into nothingness."
  ]
}
```

### Record uncertainty as uncertainty

The template's convention is `true/false/nil if unknown`. Use the third
one. It is the single most important habit here, because a guess written
into a data file reads exactly like a measurement to whoever reads it next.

- `dispellable: nil` - the 1708 wiki page never mentions dispelling and no
  dispel-side page lists it. That is **unknown**, not `false`. Writing
  `false` claims someone tried.
- `blocks_spells_at_or_above: 15` is an upper bound. 515 was refused, so
  the cutoff is 15 or lower; nothing observed says 14 is safe. The `notes`
  say so explicitly.

If a field needs a sentence of hedging, put the sentence in `notes`. A
precise-looking number with no provenance is worse than a vague one that
explains itself.

### Conventions

- **Verbatim strings.** Copy trigger lines out of the log, including double
  spaces after sentences. They are matched literally.
- **`id:` is a snake_case symbol**, stable, usually the spell name.
- **Duration in seconds**, as observed. Creature-cast durations often differ
  from player-cast: 1708 runs 30s from a creature, 180s from a player.
- **Validate before committing.** These files are eval'd hashes, so a typo
  is a runtime error:

  ```
  ruby -e 'h = eval(File.read(ARGV[0])); puts h[:abilities].inspect' path/to/creature.rb
  ```

## Where the files live

The bestiary is **upstream Lich**, not this repo: `lich-5/lib/gemstone/creatures`.
Edits belong on a branch off `elanthia-online/lich-5` main, pushed to your
own fork, and offered upstream - not kept as local patches, which a Lich
update will overwrite.

## What the engine does with it

Both halves matter, because the bestiary will never be complete:

- **Known creature** - read `abilities`, know the ceiling before casting,
  skip the blocked spells. No refusals.
- **Unknown creature** - learn from **one** refusal. `Cast` classifies the
  message as `:blocked_prepare`, `World#blocked_prepare!` records the
  ceiling, and `preconditions` skips anything at or above it until a spell
  prepares again.

The fallback is what keeps an unwritten creature file from becoming a spin,
which is why the data being incomplete is not a reason to wait.

## See also

- [docs/creature-abilities-proposal.md](../creature-abilities-proposal.md):
  priorities and status for filling out the remaining creatures
- [Troubleshooting](troubleshooting.md): what to collect when the engine
  does something unexplained
- [Contributing](contributing.md): the flow and conventions
