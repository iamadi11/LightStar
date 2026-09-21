# Tooling notes

Date: 2026-09-21

## Required for company CLI

- Python 3.10+
- PyYAML (`pip install pyyaml` if missing)
- git

## Product validation (macOS / CI)

See `company/config.yaml` → `validation.*` and `.github/workflows/ci.yml`.

## Optional Matt Pocock skills (operator-installed)

Not vendored. To install editable skills into your agent environment:

```bash
npx skills@latest add mattpocock/skills
```

Include `setup-matt-pocock-skills`, then run `/setup-matt-pocock-skills` once.

Useful companions when installed: `/tdd`, `/code-review`, `/diagnosing-bugs`, `/grill-with-docs`.

Primary source: https://github.com/mattpocock/skills
