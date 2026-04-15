# Feathered Unicorns

Configuration files for managing player access and loadouts.

> **Note:** `NAME` is just a human-readable alias. The `UID` is the only field that actually identifies a player — names are ignored by the system.

## Blacklist (`blacklist.txt`)

Players on the blacklist are banned from the server. Each entry has a `NAME` and `UID`. To ban a player, add a block:

```
NAME: PlayerName
UID: playeruid123
```

A `PUNISHMENT` field can be added to apply a specific penalty (e.g. `PUNISHMENT: MUTE`) instead of a full ban.

## Whitelist (`whitelist.txt`)

Only players on the whitelist are allowed to join test builds. Add entries the same way as the blacklist:

```
NAME: PlayerName
UID: playeruid123
```

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
