Here is your transition cheat sheet and the quickest way to turn the extension on and off.
## How to Enable and Disable Neovim Instantly
The fastest way to toggle Neovim is to use the VS Code Command Palette. You do not need to uninstall the extension to get your regular mouse and keyboard controls back.

   1. Press Ctrl + Shift + P to open the Command Palette.
   2. Type Neovim: Toggle and hit Enter.
We intend to use vscode-neovim as a UI extension, so when you're using remote development, vscode-neovim is enabled in the Local Extension Host, and it should work out of the box.
This instantly pauses the Neovim engine and restores standard VS Code behavior. Run the same command to turn it back on.
------------------------------
## The "Survive and Thrive" Neovim Cheat Sheet
Always make sure you are in Normal Mode (press Esc or your new jk shortcut) before using these keys.
## 1. Essential Mode Switches

| Key | Action | Why it's useful |
|---|---|---|
| i | Insert Mode | Start typing code before the cursor position. |
| a | Append Mode | Start typing code after the cursor position. |
| v | Visual Mode | Start highlighting text (like holding down Shift + Arrow keys). |

## 2. Advanced Navigation (Stop using the mouse!)

| Key | Action |
|---|---|
| w / b | Jump forward / backward by word. |
| 0 / $ | Jump to the absolute start / end of the current line. |
| gg | Jump to the very first line of the file. |
| G | Jump to the very last line of the file. |
| % | Jump between matching brackets () or {} or []. |

## 3. High-Speed Editing Combo Packs
Vim shortcuts can be combined like a language. For example, d means delete and w means word, so dw deletes a word.

| Key | Action |
|---|---|
| x | Delete a single character under your cursor. |
| dd | Delete (cut) the entire current line. |
| yy | Copy (yank) the entire current line. |
| p | Paste whatever you copied or deleted below the current line. |
| ciw | Change Inside Word (Deletes the current word and puts you instantly into Insert Mode to re-type it). |
| ci" | Change Inside Quotes (Deletes everything inside "hello" so you can rewrite the string instantly). |

------------------------------
## The Golden Rule of Learning Neovim
Do not try to memorize all of these at once. Pick just two shortcuts (like w for jumping words and dd for deleting lines) and focus on using only those today. Once your muscle memory takes over, come back to this list and pick two more.
Would you like to know how to map a custom keyboard shortcut (like Ctrl + Alt + V) to toggle the Neovim extension with a single keypress instead of using the Command Palette?

