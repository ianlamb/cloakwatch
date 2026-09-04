# CloakWatch

CloakWatch quietly checks raid members' equipment while you're in Blackwing Lair, so you can see at a glance who's wearing the Onyxia Scale Cloak (the cape that protects against Shadowflame and Nefarian's Corruption of Blood mechanics — critical for Hardcore).

It shows a small movable panel listing everyone in the raid with a status icon next to their name:
- 🔴 **Cloak off** — not protected, call it out
- 🟢 **Cloak on** — good to go
- ⚪ **Not yet checked** — still verifying
- 🟡 **Outdated** — hasn't been re-checked in a while (they may have swapped gear)

It only activates inside Blackwing Lair while you're in a raid group, and only tracks players actually near you (the game doesn't let you check someone's gear from across the zone). It checks people gradually in the background — never scanned first, then stale results, then confirmed-off players get rechecked before confirmed-on ones — so it stays polite to the game's own rate limits instead of hammering everyone at once.

## Technical Specs

### Activation

The addon is entirely dormant outside of Blackwing Lair. It activates only when both are true:
- `GetRealZoneText() == "Blackwing Lair"`
- `IsInRaid()`

Leaving the zone or the raid immediately stops all scanning and hides the UI.

### Roster tracking

A raid member is only tracked if they're actually rendered nearby (`UnitExists` + `UnitIsConnected` + `UnitIsVisible`) — the closest proxy Classic Era exposes to "in the same instance as me," since there's no direct API for that. Anyone who drops out of visibility is removed from tracking entirely, not just hidden. The player's own entry is exempt from this check and is always tracked.

### Player states

Each tracked player is in exactly one of four states:

| State | Meaning |
|---|---|
| **Unscanned** | Just started tracking them, no result yet |
| **Cloak on** | Last inspect found the Onyxia Scale Cloak equipped |
| **Cloak off** | Last inspect found no cloak equipped |
| **Outdated** | An "on"/"off" result older than 5 minutes — they may have swapped gear since |

### Scan priority

WoW throttles `NotifyInspect` to roughly once per second, so only one player can be checked at a time. Each second, the addon picks the next target by priority:

```
unscanned > outdated > cloak off > cloak on
```

Never-scanned players go first, then stale results get refreshed, then confirmed-off players are re-checked (in case they've since equipped it) ahead of confirmed-on players. Your own cloak is never inspected this way — it's read directly from your own equipped items and kept live via the `PLAYER_EQUIPMENT_CHANGED` event, so it's always accurate.

### Politeness / error suppression

Inspecting a player who's out of range or otherwise not inspectable throws a client error toast and a separate voiced error line. The addon guards against this by only attempting an inspect once presence, inspectability, and range all check out, with a narrow error-message filter and a temporary mute of the error-speech sound channel as a backstop for any edge cases that slip through.
