# tern-worktrees

One git branch, one worktree, one [Tern](https://stencil.so/tern) session.

Create, open, set up, and remove worktrees from Tern's command palette. Declarative `post_create` hooks handle project setup (install, env copy, optional services). Studio-friendly by default, generic enough for any monorepo.

## Status

MVP in progress. Plugin API is Tern's Luau host/window model (unversioned; Tern is closed beta).

## Install (dev)

```bash
tern plugin link /path/to/tern-worktrees
tern plugin reload
```

## Docs

- [DESIGN.md](./DESIGN.md) — product and API design
- [docs/](./docs/) — offline copy of Tern plugin docs used while building
- [tern.d.luau](./tern.d.luau) — generate with `tern plugin types .`

## License

MIT
