# Feathered Unicorns

Configuration files for managing player access and loadouts.

> **Note:** `NAME` is just a human-readable alias. The `UID` is the only field that actually identifies a player — names are ignored by the system.

Recommended to be edited with [Our ban data tool](https://github.com/realbucketofchicken/ban-list-editor)

## Blacklist (`blacklist.txt`)

Players on the blacklist are banned from the server. Each entry has a `NAME` and `UID`. To ban a player, add a block:

```
NAME: PlayerName
UID: playeruid123
```

A `PUNISHMENT` field can be added to apply a specific penalty (e.g. `PUNISHMENT: MUTE`) instead of a full ban.

## Loadout Overrides (`loadout-overrides/`)

Overrides let you give players exclusive items. Here's where we include dev cosmetics for example.

### User Groups

Defined at the top of the file with `GROUP` and `MEMBERS`. Members are listed as `Name|UID` pairs separated by commas.

```
GROUP: my_group
MEMBERS: PlayerOne|uid123,PlayerTwo|uid456
```

### Item Overrides

Each override specifies a class, slot, item, and which players it applies to:

```
CLASS: /Game/.../TF2_Soldier_HolderInfo.TF2_Soldier_HolderInfo
SLOT: Hat
ITEM: /Game/.../MyCustomHat.MyCustomHat_C
PLAYERS: PlayerName|uid123
```

Leave `UID` empty if unknown. Multiple players can be listed separated by commas.

You can also reference a group using `@group_name`, and mix groups with individual players:

```
PLAYERS: @content_creators,@devs,SomeOtherPlayer|uid789
```

### Organization & Headers

You can add headers anywhere in the file to keep things readable. The existing style uses dashes and `#` markers:

```
---------------
#-MY SECTION-#
---------------
```

Any format works as long as it doesn't start with a keyword the parser recognizes (e.g. `CLASS`, `SLOT`, `ITEM`, `PLAYERS`, `GROUP`, `MEMBERS`). Organization is important — keep related overrides grouped and labeled.

### Multiple Override Files

You can create additional override files alongside `default-loadout-overrides.txt` in the `loadout-overrides/` folder. To activate one, reference it in the **GameStateManager** inside the map. This gives you freedom to customize the game in your own map.
