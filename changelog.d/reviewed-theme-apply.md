### Added

- `macarchy theme set --dry-run` (and its `--json` output) now shows a plan for every
  enabled consumer: what changes, the generated files it reads, when the change
  shows (live, reload, next prompt, fresh session…) and its preflight result, plus
  the consumers disabled in the profile. Every preflight failure is listed, not
  just the first. `macarchy theme set <theme> --reviewed <digest>` applies exactly
  that plan and is refused when the theme, its background, the enabled consumers or
  the active theme changed since the review.
