# LiveWorld RPG 0.46.14

LiveWorld RPG is an offline, single-player fantasy RPG with isometric 2.5D graphics, written in Python with pygame. You play in a large living world with 12 classes, instanced dungeons and raids, PvP battlegrounds, crafting, gathering, fishing, mounts, and about 640 computer-controlled adventurers.

For the full player's guide, see `LiveWorld-RPG-0.46.14-Complete-Guide.docx`, or press **F1** in the game.

## What's new in 0.46.14

- **Smaller package.** A leftover Python cache file (`__pycache__/engine.cpython-313.pyc`) is no longer included. The download shrinks from 488 KB to 365 KB and the installed size from 2204 KB to 1560 KB. There are no gameplay changes, and apt installs it as a normal upgrade over 0.46.13.

### From 0.46.13

- **"IN COMBAT" no longer gets stuck.** Combat now clears after 10 seconds with no hits, no spells and no movement. Before this fix, a monster that couldn't reach you (for example, one stuck across a river) kept you in combat forever. That stopped health from regenerating and blocked fishing, eating and leaving dungeons. Monsters that give up the chase leave you alone for about 50 seconds.

## Files in this release

| File | What it is |
|---|---|
| `liveworld-rpg_0.46.14_all.deb` | Installable Debian package (architecture `all`) |
| `liveworld-rpg-0.46.14-source.tar.gz` | The unpacked package tree (`DEBIAN/` + `usr/`), the same files that are in the .deb |
| `SHA256SUMS-0.46.14.txt` | SHA-256 checksums for the two files above |
| `LiveWorld-RPG-0.46.14-Complete-Guide.docx` | Install guide, controls and the full in-game guide |

## Verify the download

Put `SHA256SUMS-0.46.14.txt` in the same folder as the downloads and run:

```bash
sha256sum -c SHA256SUMS-0.46.14.txt
```

Both lines must say `OK`. Expected values:

```
4455cdd2ef07d2146df5d5fd8cc04c4295ec21f4739ffa53075e749e3cea2775  liveworld-rpg_0.46.14_all.deb
524553757b170b334e4af3886ccd1cafc8dc0c083c362f4e3d492c6236b6da55  liveworld-rpg-0.46.14-source.tar.gz
```

## Requirements

- Debian, Ubuntu, Linux Mint or another Debian-based Linux (any CPU)
- `python3`, `python3-pygame`, `python3-numpy` (apt installs these for you)
- Recommended: `x11-utils` for correct full-screen sizing

## Install

```bash
sudo apt install ./liveworld-rpg_0.46.14_all.deb
```

Keep the `./` so apt installs the local file and fetches the dependencies. Installing over an older version keeps your saves. If you used `dpkg -i` and it reported missing packages, run `sudo apt -f install`.

## Play

Start it from **Applications → Games → LiveWorld RPG**, or run:

```bash
liveworld-rpg
```

The first start builds the world (about half a minute). Later starts use a cache.

To create a hero from the terminal instead:

```bash
liveworld-create-character NAME Alliance|Horde CLASS [SPEC]
```

### Key controls

| Input | Action |
|---|---|
| Left click | Walk / target a monster and auto-attack with your weapon |
| 1–0, Shift+1–6 | Class spells / capstone spells (levels 30–80) |
| W A S D / arrows | Move |
| Space or E, Tab | Attack nearest / next target |
| F | Talk, gather, enter, use buildings |
| H / J / T / Y / V / Z / G | Health potion / mana potion / teleport / buff / eat / loot / fish |
| I / C / K / U / M / Q | Bag / Hero / Skills / Stats / Map / Quests |
| X | Mount / dismount |
| O / N | Leave dungeon / skip rest |
| F1 / F9 / F10 / F11 / Esc | Guide / Lite graphics / High–Ultra / Full screen / Settings |

## Saves and logs

| What | Where |
|---|---|
| Characters, saves, settings | `~/.local/share/liveworld-rpg` |
| Startup log | `~/.local/state/liveworld-rpg/startup.log` (the previous run is kept as `startup.log.1`) |

The world saves every 30 seconds and when you quit.

## Troubleshooting

| Problem | Fix |
|---|---|
| Window opens then closes | Read `~/.local/state/liveworld-rpg/startup.log`. If pygame is missing, run `sudo apt install python3-pygame python3-numpy`. |
| "Already running" | Only one copy can use a save at a time. Switch to the open window. |
| Slow or choppy | Press F9 to step graphics between Lite, Normal and High. |
| HUD hidden under a desktop panel | Esc → Settings → Display → Borderless or Window |
| Nights too dark | Raise Brightness in Settings. |
| "IN COMBAT" won't go away | Fixed in 0.46.13. Stop attacking and stand still for 10 seconds, then walk away from the monster. |

## Uninstall

```bash
sudo apt remove liveworld-rpg
```

You can also use **Uninstall LiveWorld RPG** in the applications menu. It asks whether to keep or delete your saves.

## Building the .deb from source

```bash
tar xzf liveworld-rpg-0.46.14-source.tar.gz
dpkg-deb --root-owner-group --build liveworld-rpg-0.46.14 liveworld-rpg_0.46.14_all.deb
```

A rebuilt package installs the same files. Its SHA-256 will not match the published one, because file timestamps inside the archive differ. Check the published .deb against `SHA256SUMS-0.46.14.txt`, not a rebuilt one.

## Recent changes (0.46.x)

- **0.46.14**: Smaller package. The leftover Python cache file is no longer included. No gameplay changes.
- **0.46.13**: "IN COMBAT" can no longer get stuck. It clears after 10 seconds with no hits, no spells and no movement.
- **0.46.12**: The big gold `?` quest dots are gone from the minimap. The Quest Giver window no longer overlaps its messages.
- **0.46.11**: Gear and Mats tabs show only their own list. Quest tooltips added. Fishing messages now show on screen.
- **0.46.10**: One tooltip style everywhere, and tooltips fade when the mouse leaves.
- **0.46.9**: Gear tooltips in the War Hall and the vault.
- **0.46.8**: Alliance cities are blue and Horde cities are red.
- **0.46.7**: The War Hall name plate sits above the roof.
- **0.46.4–0.46.6**: Magic monsters (Arcane Dust droppers) appear in every zone, with violet markings. Existing saves get them too.
- **0.46.3**: A pickup notice for every item, coloured by rarity.
- **0.46.1–0.46.2**: Pulsing gold quest areas on the maps replace the misleading quest dots.
- **0.46.0**: Magic Shop, Forge upgrades +1 to +5, six-piece sets with 2/4/6-piece bonuses, Mythic bonuses, new spell and weapon effects.

The full history is in the package description (`apt show liveworld-rpg`) and in `/usr/share/metainfo/liveworld-rpg.metainfo.xml`.
