## Useful command examples

Create a file:

```bash
cat <<'EOF' > newfile.py
print("hello")
EOF
```

Edit a file in place:

```bash
sed -i 's/old_string/new_string/g' filename.py
```

Read part of a file with line numbers:

```bash
nl -ba filename.py | sed -n '10,20p'
```
