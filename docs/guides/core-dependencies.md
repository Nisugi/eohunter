# Core dependencies

The engine leans on Lich for everything Lich can do: combat parsing,
the PSM readers, the spell and effect state, item handling, routing,
the group, the societies. It needs Lich 5.22.0 or later, the first
release carrying every lich-5 pull request below. This page lists what
each provided and what in the engine uses it.

## The check at startup

`eohunter.lic` checks for a few constants before it loads the engine
(`Lich::Gemstone::Fog`, `Combat::Messages`, `Stance`, `Mana`) and exits
with a message to update Lich to 5.22.0 when one is missing. Those are
the sentinels; the full list below is what the engine actually uses.

## lich-5 pull requests the engine consumes

All merged in September 2026 and released in Lich 5.22.0.

| PR | Provides | Used by |
|---|---|---|
| #1578 | `Lich::Gemstone::Stance`, a shared stance setter | every stance change |
| #1579 | `Lich::Stash.wield`, `Stash.hands`, `Stash.open_container` | wield and store, the refused-fire stow |
| #1580 | `Lich::Gemstone::Mana.pulse` | Cleanse, the fog return |
| #1581 | `Lich::Gemstone::Bank`, Currency refresh, WEALTH lines | the bounty objective |
| #1582 | the Injured cache on the class, keyed on an injury fingerprint | the ability gates |
| #1583 | PSM `command` and `results_regex` readers | every maneuver |
| #1584 | `Lich::Gemstone::Fog`, the ways home | Rest's fog return |
| #1585 | a spell's start message refreshes a refreshable timer | Maintain's timing |
| #1586 | `Combat::Messages`, non-combat message families as observer events | the watch |
| #1587 | bounded `fput`: `max_resends`, `interrupt`, `resend_transient`, failure symbols | the send ladder |
| #1588 | `Group.broken?` waits on `Lich::Claim::Lock` | the claim |
| #1589 | society `command` readers | Wrack, the symbols and sigils |
| #1590 | `Spell.results_regex` | cast confirmation |
| #1591 | `Group.join` | the follower's join |
| #1575 | opt-in bounded script execution guards (ATARI) | the LAB controller only |
| #1576 | combat observation provenance (ATARI) | the LAB controller only |
| #1577 | static-only map route selection (ATARI) | the LAB controller only |

The last three are not needed for ordinary hunting.

## Older Lich features

Everything else the engine reads was in Lich before these: `Lich::Claim`,
`Lich::Gemstone::Status`, `Injured`, `Experience`, `GameObj.targets`
and `hidden_targets`, `Overwatch`, `Creature` and `CreatureInstance`,
`Combat::Observers` and `Tracker`, `Group`, `Bounty`, `StowList`,
`CMan` and the other PSM modules, `Armaments::WeaponStats`, `Wounds`,
`Societies`, `Map`, the `check*` globals. The core consumption audit
(`docs/core-consumption-audit.md`) walks each engine file and names
what it reads.

## A new core feature

When the engine needs something Lich does not have, the feature goes to
lich-5 as a pull request, and the engine waits for the Lich release that
carries it rather than working around it. Raise the `required:` line in
`eohunter.lic`'s header and the startup check with it.
