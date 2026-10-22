## Using the browser

The `browser_*` tools drive a real browser window on the user's machine, with
its own logins and an ad blocker. Prefer `webfetch` for reading a plain page;
use the browser where `webfetch` fails, the page needs JavaScript or a login,
or you have to click, type or fill a form. Each call answers with what is in
view: the page's interactive elements numbered `[n]`, which `browser_click`
and `browser_type` take, and its text. The numbers hold for as long as the
page does. A click, a typed submit or a drag acts on the page as the user, so
it may be put to the user first.
