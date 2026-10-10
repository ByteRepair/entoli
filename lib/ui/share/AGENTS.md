# Sharing to Entoli

`MainActivity` carries `ACTION_SEND` / `ACTION_SEND_MULTIPLE` filters, and so
does the `PromptIcon` alias — only one of the two components is enabled at a
time, and a share must not stop working because the user changed the icon.

`FilesChannel.receive` copies whatever the intent carries into `cacheDir` **at
once**, from `onCreate` and `onNewIntent` alike: the read permission on those
URIs is granted to the task and dies with it, and the user takes a while to pick
a workspace. The intent's action is then cleared, so an activity recreated from
the same one does not stage the share twice. A batch arriving with nothing
already waiting empties the directory first — a share the user backed out of is
never claimed, and nothing else would ever delete its copy.

Dart claims them from `IncomingShares`, which wraps the app in `main` rather
than living in `AppShell`: a share has to be offered a workspace over whatever
is on screen, and a `Navigator` to push that onto only exists below
`MaterialApp`. It reads twice over and needs both — once after the first frame,
for the share that launched the app and was staged before Dart was listening,
and once per `shareArrived`, for one that arrives while the app is already up.
Reading empties the queue, so a share is offered a workspace exactly once.

The nudge is what carries the cached engine's case, and it is the reason there
is one. A share into an activity whose engine was cached runs `onCreate` but not
`main`, so `initState` does not fire again and the first-frame read never
repeats — but the channel is still registered and the widget still subscribed,
so the invoke lands. See "Staying alive off screen".

`ShareTargetPage` is that offer: every workspace Entoli has, as a list — the
default project, each project beside it, then each chat's own — and picking one
writes the files there and closes. Nothing else is on it, because a share
arrives with nowhere to go and asking is the whole of what the page is for.

A path that arrived from outside is sanitised by `safeRelativePath` before it is
joined onto anything: the sharing app wrote it, and `../../settings.json` is a
name a file can have. Folders in it are kept — that is what makes a folder
upload survive — and only the segments that would climb are dropped.

A staged copy is **moved** into the workspace rather than read out of it. The
cache and the data directory are one volume, so the move is the real path and
the bytes never enter this process; the copy it falls back to is there because
"one volume" is an assumption about a device rather than a guarantee.

Moving consumes the copy, which is what makes the staging directory tidy itself
and is also the reason `FilesChannel` prunes it on the way **out** rather than
on the way in. Dart now holds the staged paths until a workspace is picked, so a
second share arriving while that page is open would delete the paths the page is
still pointing at. At `takeShare` there is no such hazard: only one batch is ever
offered at a time, so anything left beside the batch being handed over is an
earlier one nobody claimed.
