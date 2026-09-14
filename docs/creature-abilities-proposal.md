# Creature ability data: proposal

## Why

On 2026-09-13 a branded goliath diviner cast Mystic Impedance (1708) on us.
515 (Rapid Fire, level 15) became unpreparable for 30 seconds. The engine
did not know this, so it re-sent `incant 515` **48 times in ~4 seconds**
until the debuff expired.

Two independent defects produced that:

1. **The refusal was scored as a success.** `Cast#perform` matches a list of
   known refusals; the Mystic Impedance line matches none of them, so it fell
   through to `return Result.new(status: :success)`. A blocked cast counted as
   a cast, which reset the failure streak and hid the loop from the spin
   detector.
2. **The creature's ability was not recorded.** `branded_goliath_diviner.rb`
   already carries the tell (`messaging.spell_prep`, the "flicks a finger at
   you" line) but nothing says what the finger-flick *does*. There was no data
   to gate on.

Defect 1 is an eohunter fix. Defect 2 is a data gap across the whole bestiary,
and is what this proposal is about.

## The gap

In `lich-5/lib/gemstone/creatures` (628 files, schema v3):

| Field | Populated |
|---|---|
| `abilities:` (the structured block) | **2 / 628** (`bloody_halfling_cannibal`, `tattooed_gigas_berserker` — both `:frenzy`) |
| `messaging.spell_prep` | **169** files |
| `warding_spells` / `offensive_spells` / `bolt_spells` | ~1 each |

So ~169 creatures are known to cast *something*, and almost none of them say
what. The template already designed the slot for this; it just was never
filled in.

## What "done" looks like for one creature

The template's `abilities:` block is the designated home. For the diviner:

```ruby
abilities: [
  {
    id: :mystic_impedance,
    name: "Mystic Impedance (1708)",
    type: :debuff,
    target: :opponent,
    typical_duration_s: 30,
    effects: { blocks_spells_at_or_above: 15 },
    dispellable: nil,
    notes: "Golden runes onset. Blocks the PREPARE of spells at or above " \
           "the threshold; lower spells still work. Threshold is an upper " \
           "bound (515 observed blocked); exact floor unconfirmed."
  }
]
```

plus the onset line under `messaging.triggers` so the runtime can key on it,
and `"Mystic Impedance (1708)"` added to `attack_attributes.offensive_spells`.

### Record uncertainty honestly

The template's own convention is `true/false/nil if unknown`. Use it.

- `dispellable: nil` — the 1708 wiki page never mentions dispelling and no
  dispel-side page lists it. That is *unknown*, not `false`.
- `blocks_spells_at_or_above: 15` is an **upper bound**. The log proves 515 was
  blocked, so the cutoff is ≤15. It does not prove 14 is safe. A later
  *successful* lower cast tightens it.

A guessed value that looks measured is worse than `nil`, because the next
person builds on it. Say what was observed and where.

## Filling out the rest

### Priority order

1. **The 169 with a `spell_prep` tell.** Highest value: the tell is already
   recorded, so only the consequence is missing, and these are the creatures
   demonstrably doing something to us.
2. **Creatures in areas we actually hunt.** Cross-reference `areas.uids`
   against the profiles in use. A perfect entry for something never fought is
   worth less than a rough one for a current hunting ground.
3. **Everything else**, opportunistically.

### Where the data comes from

- **Session logs** are the best source and we have a lot of them. Onset,
  wear-off, duration and the mechanical effect are all in the XML — the
  Debuffs/Buffs `dialogData` carries the spell number, the display name and a
  countdown. That is how 1708 was identified here: `progressBar id='1708'
  text="Mystic Impedance" time='00:00:30'`.
- **The wiki dump** (`E:\Gemstone\data\wiki_clean`) for the spell's mechanics
  once the number is known.
- **Never from the name alone.** Two wrong identifications were made during
  this investigation by matching an effect to a plausible-sounding spell
  (Mindwipe, then Corrupt Essence 703). Both were discarded only because the
  log disagreed. Confirm the number in the dialog before writing it down.

### A repeatable procedure

For a creature suspected of casting something:

1. Find the onset in an XML log (`grep` the `spell_prep` line, or the effect
   text).
2. Diff the `Buffs` / `Debuffs` / `Active Spells` `dialogData` across that
   line. The new `progressBar id=` is the spell number; its `time=` is the
   duration.
3. Find the wear-off message; onset + wear-off bracket the effect.
4. Look the number up in the wiki dump for mechanics.
5. Write the `abilities:` entry, `nil` for anything not actually observed.

Step 2 is mechanical and is the part worth scripting — a small tool that takes
a log and a line number and prints the dialog delta would make this cheap
enough to do in bulk.

## Consuming it in eohunter

Independent of how complete the data is, the engine wants both halves:

- **Known creature** → read `abilities`, know the threshold before casting,
  skip blocked spells entirely. Zero refusals.
- **Unknown creature** → learn from **one** refusal: classify the line as a
  transient failure, read the Debuffs dialog to see what landed, infer the
  threshold, suppress affected spells until the effect expires. One refusal,
  not 48.

The fallback is what keeps an incomplete bestiary from being a spin, which is
why it is not worth waiting for the data to be complete before shipping the
engine fix.

### Note on file ownership

`lich-5/lib/gemstone/creatures` is **upstream Lich**, not this repo. Edits
there can be overwritten by a Lich update, and belong upstream rather than as
local patches. Worth settling before bulk editing.

## Status

- [ ] eohunter: match the refusal line, classify as transient, stop scoring it
      `:success`
- [ ] eohunter: infer + cache the threshold for the effect's duration
- [ ] `branded_goliath_diviner.rb`: the `abilities` entry above
- [ ] Tooling: dialog-delta helper for log mining
- [ ] The other 168 `spell_prep` creatures
