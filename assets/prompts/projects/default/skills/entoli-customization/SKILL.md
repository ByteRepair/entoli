---
name: entoli-customization
description: Change the user's Entoli settings, such as their profile (name, date of birth, religion, profession) or the tone replies are written in. Use only when the user asks to change one of these, or when an agent's instructions say to.
metadata:
  user-invocable: "false"
---
Loading this skill gives you two tools that change Entoli's own settings. They
write the app-wide settings the user sees under Profile, so only call them
with what the user told you, and say what you changed.

- `set_profile` sets fields of the user's profile: `name`, `date_of_birth`
  (as `YYYY-MM-DD`), `religion` and `profession`. Pass only the fields you
  are changing; the others stay as they are. An empty string clears a field.
- `set_tone` sets the tone replies are written in: `default`, `direct`,
  `kind` or `formal`.

The profile and the tone reach every later turn in every chat, so a change
shows from your next reply on.
