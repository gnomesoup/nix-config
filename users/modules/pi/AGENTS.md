# Global agent instructions

## Herdr orchestration

When starting a Pi worker through Herdr, disable the interactive Ask tool so the worker cannot block orchestration on a questionnaire:

```bash
herdr agent start <name> --kind pi --pane <pane-id> -- \
  --exclude-tools ask_questions
```

Do not use `--no-extensions` for this purpose because the worker still needs Herdr's Pi lifecycle integration and other configured extensions.
