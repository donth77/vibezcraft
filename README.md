# Minecraft Alpha Clone

A from-scratch, AI-assisted clone of Minecraft Java Edition Alpha (2010), built in Godot 4 + GDScript.

## Docs
- [`.claude/PLANNING.md`](./.claude/PLANNING.md) — vision, stack rationale, Alpha mechanics reference
- [`.claude/implementationplan.md`](./.claude/implementationplan.md) — phase-by-phase execution plan

## Run

```sh
godot --path .                         # open in editor
godot --path . main.tscn               # run main scene directly
```

## Test

```sh
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests/ -gexit
```

## Lint & format

```sh
gdformat --check scripts/ tests/       # check formatting
gdformat scripts/ tests/               # apply formatting
gdlint scripts/ tests/                 # lint
```

## First-time setup (per developer)

```sh
./scripts/dev/install-hooks.sh         # install git pre-commit hook
```
