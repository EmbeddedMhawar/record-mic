# Audsync — Project Rules

## Version Control
- Always commit working changes before starting new edits.
- Use descriptive commit messages that explain *why*, not just *what*.
- Never amend published commits — create new commits instead.
- Tag versions as vX.Y.Z with a short description in the commit message.

## Testing
- After every code change, verify it works before considering the task done.
  - For shell scripts: run `bash -n record-mic.sh` (syntax check) at minimum.
  - For Python: run `python -c "import audio_sync"` to verify no import/syntax errors.
  - If a device-dependent feature can't be tested live, at least dry-run the logic path.
- Do not assume edits are correct — confirm with a test or verification step.
