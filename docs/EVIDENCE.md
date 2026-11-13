# API and item-identity evidence

## Exact NTM Extended 2.0.2 item evidence

Inspected release:

- Modrinth project `9Y3a7djB`, version `9pJC8bY8`
- file `NTM-Extended-1.12.2-2.0.2.jar`
- size `63,613,333` bytes
- SHA-256 `9BAADA65B6FD25740544C525EDA07C10113EB759457643C9E296797D60EAC822`
- release page: https://modrinth.com/mod/ntm-extended/version/2.0.2

Evidence inside that exact JAR:

- `mcmod.info` declares `"modid": "hbm"` and version `2.0.2`.
- decompiled `com.hbm.items.ModItems` constructs
  `new ItemGeigerCounter("geiger_counter")`.
- `assets/hbm/advancements/progress_geiger.json` uses the item value
  `"hbm:geiger_counter"` for both its icon and inventory-change criterion.
- `assets/hbm/models/item/geiger_counter.json` and the corresponding textures
  are present.

Conclusion: `hbm:geiger_counter` is the evidence-backed default for this exact
release. The config remains editable and requires in-game confirmation because
the running server can contain scripts, forks, or later changes.

## OpenComputers API evidence

RACS uses documented OpenComputers/OpenOS interfaces:

- Transposer component:
  https://ocdoc.cil.li/component:transposer
  - `getInventorySize(side)`
  - `getInventoryName(side)`
  - `getStackInSlot(side, slot)`
  - `getAllStacks(side)`
  - `transferItem(sourceSide, sinkSide, count, sourceSlot, sinkSlot)`
- Modem component:
  https://ocdoc.cil.li/component:modem
  - `open`, `send`, `broadcast`, `maxPacketSize`, `isWireless`, `setStrength`
- Network signal layout:
  https://github.com/MightyPirates/OpenComputers/wiki/Signals
  - `modem_message(receiverAddress, senderAddress, port, distance, ...)`
- Serialization:
  https://ocdoc.cil.li/api:serialization
  - `serialize` and `unserialize`; tables are serialized into one string before
    modem transmission because modem payload parts accept basic values.
- OpenOS filesystem:
  https://github.com/MightyPirates/OpenComputers/wiki/API-Filesystem
  - directory creation, copy, remove, rename, existence checks, and file I/O.

The code is written for the Lua 5.2 environment used by OpenComputers and avoids
Lua 5.3-only syntax.

