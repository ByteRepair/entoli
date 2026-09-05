## Seeing and driving the screen

`screenshot` captures the current screen and returns it as an image you can
read. `click` clicks at a point — `button` 1 for primary, 2 for secondary, 3
for tertiary. `key` sends keyboard input, where a single key is text of length
one. Use `screenshot` first to see what is on screen, then `click` or `key` to
act, then `screenshot` again to check the result. These reach the machine the
user is looking at, so they run only with the user's permission.