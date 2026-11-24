# Omarview

Mission Control for [Omarchy](https://omarchy.org/). One overlay shows your workspaces and the windows on them, with a live picture of each window.

Open it from the top-right corner of the screen, or with F3. On a Mac keyboard the F3 key sends `XF86LaunchA` unless Fn is held, so both keys are bound. Arrow keys move between workspaces and windows, Enter opens the selection, and Esc closes the view. Click a window to focus it, or click the empty area around the cards to close.

## Install

Omarview is an Omarchy shell plugin plus a short Hyprland script. Clone it somewhere stable, then link the plugin into your shell config:

```sh
git clone https://github.com/ergofobe/omarview.git ~/src/omarview
ln -sfn ~/src/omarview/plugin ~/.config/omarchy/plugins/omarview
```

Enable it in `~/.config/omarchy/shell.json`. Third-party plugins are objects, not bare names:

```json
"plugins": [
  { "id": "omarview" }
]
```

The shell reloads plugin changes on save. If the overlay does not appear, run `omarchy-shell shell rescanPlugins`.

Bind the keys in `~/.config/hypr/bindings.lua`:

```lua
o.bind("F3", "Omarview", { panel = "omarview" })
o.bind("XF86LaunchA", "Omarview", { panel = "omarview" })
```

Load the hot corner from `~/.config/hypr/hyprland.lua`, after the Omarchy defaults:

```lua
dofile(os.getenv("HOME") .. "/src/omarview/hypr/omarview.lua")
```

Then check the config:

```sh
hyprctl reload
hyprctl configerrors
```

The corner is the top 8 logical pixels of the right edge. It waits about a fifth of a second before opening, and it does not fire again until the pointer leaves. If the pointer is already in the corner when Hyprland reloads, the overview stays closed.

## Live previews

Each tile is a Hyprland toplevel capture. While the overview is open, Omarview asks every window to keep drawing (`render_unfocused`) and raises `misc.render_unfocused_fps` to 30. A one-pixel pulse in the overlay makes the monitor commit, which is what delivers the next frame. Closing the overview restores the previous frame rate and turns the window flag back off.

A window that refuses to draw while it is covered will stay on its last frame. That is the client, not the capture. Copies are full size for as long as the overview is open.

## License

Apache License 2.0. See [LICENSE](LICENSE).
