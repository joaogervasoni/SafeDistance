# Changelog

## Unreleased

- Fixed the box staying on screen after leaving a dungeon.
- `/sd` now opens the options and `/sd help` the list of commands.

## 1.1.0

- Distances now show half yards, so 17.5 yd no longer shows up as 17.
- The chat message after each pull is now off by default. 
    - _Turn it back on with `/sd chat` or the checkbox in the options_

## 1.0.0 - first release 🎉

- A small box above your action bars shows the distance to your target, its aggro radius and a ruler: green is safe, yellow is the edge, red is too close.
- While you're stealthed, the ruler turns purple and shows the mob's detection range instead.
- It learns from every pull and remembers the distance for your level.
- What it learns is kept per zone and per dungeon. Open-world numbers are never used inside dungeons.
- Warns you about mobs that usually bring friends.
- A colored dot next to the target's nameplate, so you don't have to look down.
- `/sd window` shows what it learned, and you can delete anything that looks wrong.
- Settings are in Options -> AddOns -> Safe Distance.
- Tells you when a mob is already fighting someone else, or is neutral.
- English and Brazilian Portuguese.
- Does nothing while you don't have a hostile target, so it shouldn't cost you FPS.
- If the game refuses to answer a check, you won't get Lua errors. `/sd debug` shows which ones failed.
