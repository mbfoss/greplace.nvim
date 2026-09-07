# sundial

A small static-site generator. Pages are Markdown files under `pages/`;
`sundial build` renders them into `public/`, and `sundial serve` keeps the
directory open on a local port while you edit.

Configuration lives in `sundial.toml`. It is optional: every setting has a
default, and `load_config` in `src/config.lua` fills in whatever the file
leaves out.

```toml
source = "pages"
output = "public"
port = 8080
watch = true
```

The command line is in `src/cli.lua`, the development server in
`src/server.lua`, and the tests run with `busted tests/`.
