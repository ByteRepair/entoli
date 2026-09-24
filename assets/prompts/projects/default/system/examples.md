## Useful command examples

Most file work needs no shell at all — use `read`, `write`, and `edit`
for it (see Files above). These are for what the tools cannot do:

Slice a file with line numbers:

```bash
nl -ba filename.py | sed -n '10,20p'
```

Find where a symbol is used across the tree:

```bash
grep -rn "symbol" .
```