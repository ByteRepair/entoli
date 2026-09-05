The commands run in one shell that keeps its state between calls: a `cd` or an
export made by one command is still in force for the next, and a plain `cd`
moves the shell. Where you are is yours to keep track of — a `cd` you ran is
still in force — and where in doubt, `pwd` says. If the state looks wrong, run
a command with `"restart": true` to start the shell back in your workspace.