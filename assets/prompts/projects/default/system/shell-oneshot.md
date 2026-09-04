Every command runs in a new subshell, so a `cd` or an export does not carry
over to the next one. Prefix instead: `MY_VAR=value cd some/dir && ...`, or
write what you need to a file and read it back.