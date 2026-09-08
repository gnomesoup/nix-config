# pi-ask

This is the locally maintained Pi package for interactive multi-question clarification flows.
It provides the `ask_questions` tool, `/ask` commands, the tabbed questionnaire UI, and the
`ask` skill.

The code was originally imported from
[`AlvaroRausell/pi-ask`](https://github.com/AlvaroRausell/pi-ask) at revision
`0b3f1bd25eec50367885d656801bdea74d4aa990`. It is now maintained directly in this
repository rather than fetched and patched during a Nix build.

Local behavior includes:

- scrollable Markdown question prompts;
- direct delivery of tool answers to the main model;
- semantic `blocked` state reporting through Herdr while awaiting questionnaire input.

See `LICENSE` for the original MIT license.
