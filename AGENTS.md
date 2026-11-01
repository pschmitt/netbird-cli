# Agent guidance

`netbird-cli` is a Bash wrapper for the NetBird management API.

## Development

- Requirements: Bash, `column`, GNU awk, `curl`, and `jq`.
- Check shell syntax with `bash -n netbird-cli.sh` and use the script's help output to review CLI options.
- Do not use a real API token or call a live management API when validating changes.
- Load the `shell` skill before changing shell code.

## CI

- Before changing CI, inspect the current guidance in `pschmitt/ci-workflows`. Pin shared reusable workflow and action references to `@main`.
