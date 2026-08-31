# job-compass — instructions for coding agents

Vendor-neutral by design: `CLAUDE.md` is a symlink to this file, so every tool reads
one source. Repository purpose: see [README.md](README.md).

## Layout

| Path | Holds | Ships in the wheel |
|---|---|---|
| `src/job_compass/` | all application code | yes |
| `tests/unit/`, `tests/integration/` | tests | no |
| `db/sqlite/migrations/` | schema, one numbered file per change | no |
| `docs/` | architecture notes, runbook | no |
| `.github/workflows/` | CI | no |

The rule behind the table: **what is needed at runtime lives inside the package;
what is needed only by a developer lives outside it.** Only `src/job_compass` is
listed in `[tool.hatch.build.targets.wheel]`, so a top-level directory is not
importable. Evaluation harnesses (`evals/`) and generated code (`gen/`) therefore
belong inside the package when they arrive; tests and migrations do not.

## Conventions

- **English only** — code, comments, docs, README, commit messages. No exceptions.
- **Source goes in git, derived output does not.** Migrations are source; the
  database is not. It holds real applications, real companies and real people's
  contact details, and this repository is public.
- **`uv` owns the environment.** Never `pip install` into `.venv`, never create it
  with `virtualenv`. `uv sync` after pulling; `uv add <pkg>` to add a dependency —
  both `pyproject.toml` and `uv.lock` update together. `uv.lock` is committed and
  never hand-edited.
- **`pyproject.toml` is the only home for tool configuration.** No `setup.cfg`,
  no `.flake8`, no `mypy.ini`, no `pytest.ini`.
- **Tooling that only the repository needs goes in `[dependency-groups]`**, never in
  `[project.optional-dependencies]`.
- **No absolute paths anywhere in the repository.** They do not resolve for anyone
  else and they leak the layout of a private machine.

## Commands

`make help` lists them. The ones that matter:

```
make install     # sync the environment from uv.lock
make check       # lint + typecheck + test, in the order CI runs them
make migrate     # apply every migration to the local database
```

## What CI gates

`ruff check` → `ruff format --check` → `mypy --strict` → `pytest tests/unit`.
All four block a merge. `uv sync --locked` fails the build when `uv.lock` is stale.

A check that nothing triggers is documentation, not a gate: anything worth
enforcing goes into the workflow, not into this file as a request.

## Open decisions

- **Migration direction.** `001_init.sql` announces a numbered series. Decide
  forward-only vs. paired up/down **before `002` is written** — after that the
  convention has set itself by accident.
- **Where generated code lands**, once anything generates code: `src/job_compass/gen/`,
  built by `make`, with commit-or-not decided at that point.
