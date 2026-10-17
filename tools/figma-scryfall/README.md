# Scryfall Fill (Figma plugin)

Fills layers in the selected frame, component or instance with card data from Scryfall: name, image, mana cost, colors, prices and more. Plain JS, no build step.

## Install

Figma desktop app → **Plugins → Development → Import plugin from manifest…** → pick `tools/figma-scryfall/manifest.json`. Run it from **Plugins → Development → Scryfall Fill**.

## Use

1. Select a card frame/component/instance (or several).
2. Type in the search box. Any Scryfall syntax works: `bolt`, `t:goblin c:r`, `!"Lightning Bolt"`, `set:mh3 r:mythic`.
3. Click a card to fill every selected item with it. **Enter** fills the first result.
   - **Fill each**: with several items selected, gives each its own result in reading order (rows top to bottom, left to right).
   - **Random**: a random card matching the query (one per selected item).
   - **All printings**: lists every printing, newest first, so you can pick a specific art or set.
   - **Hide empty layers**: hides e.g. `#pt` on non-creatures and `#flavor_text` when there is none.
4. A filled item gets a **Swap card** button in the right panel to reopen the plugin.

**New card component** drops a starter component (Table 1 colors) with the common layers already named.

## Layer names

Name a layer `#field`. Anything after the field name is ignored (`#name copy` still works). Instances also match **text component properties** with the same names (`Name`, `Mana cost`, `Type line` …).

| Kind | Fields |
| --- | --- |
| Text | `#name` `#full_name` (both faces) `#mana_cost` `#cmc` `#type_line` `#oracle_text` `#flavor_text` `#power` `#toughness` `#pt` (P/T, else loyalty/defense) `#loyalty` `#defense` `#set` (code, upper case) `#set_name` `#collector_number` `#rarity` `#artist` `#released_at` `#lang` `#colors` `#color_identity` `#keywords` `#price` `#price_foil` `#price_eur` `#id` `#scryfall_uri` |
| Image fill | `#image` (large) `#art` (art crop) `#image_normal` `#image_png` `#image_small` `#border_crop` |
| Color fill | `#color` (W/U/B/R/G color, gold for multicolor, grey for colorless; lands use color identity) |

- Aliases: `#mana`, `#type`, `#text`/`#oracle`, `#flavor`, `#number`, `#mv`.
- Any other top-level Scryfall field works as text too (`#edhrec_rank`, `#border_color`, …).
- `#back.<field>` reads the back face of double-faced cards (`#back.name`, `#back.art`, `#back.pt`).
- A frame named like a text field (e.g. a `#pt` box) fills its first text layer and hides as a whole when empty.
- Image fills keep the layer's existing scale mode (Fill/Fit/Crop).

Mana costs come through as text (`{2}{U}{U}`); swap in symbol glyphs with a font that has them if you need icons.
