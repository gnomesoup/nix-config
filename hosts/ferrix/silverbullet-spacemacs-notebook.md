# Spacemacs Notebook

A fixed dark theme using the Spacemacs palette already used by your other apps.
Proportional prose, restrained headings, and reading-focused spacing distinguish
SilverBullet from Nvim. Code remains monospace; keyboard bindings are unchanged.
No remote fonts, scripts, or other external assets are loaded by this theme.

Managed by Nix from `hosts/ferrix/silverbullet-spacemacs-notebook.md` in
`nix-config`. Edit that source and rebuild Ferrix; direct edits to this page are
replaced by the next managed-file synchronization in Personal and KSP.

After deployment, reload SilverBullet or run `System: Reload`.
To restore the built-in appearance, change the source fence from `space-style`
to `css`, rebuild, and reload. This theme intentionally stays dark regardless
of the built-in light/dark setting.

```space-style
html:root {
  color-scheme: dark;
  --ui-font: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --editor-font: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --editor-monospace-font: "Iosevka", "JetBrains Mono", "iA-Mono", monospace;
  --editor-width: 48rem;

  --root-background-color: #292b2e;
  --root-color: #b2b2b2;
  --ui-accent-color: #a45bad;
  --ui-accent-text-color: #bc6ec5;
  --ui-accent-contrast-color: #ffffff;
  --ui-surface-background-color: #292b2e;
  --ui-surface-color: #b2b2b2;
  --ui-surface-subtle-color: #9a9a9a;
  --ui-surface-border-color: #414047;
  --ui-surface-section-background-color: #242428;
  --ui-surface-hover-background-color: #34323b;
  --subtle-color: #9a9a9a;
  --subtle-background-color: #242428;
  --meta-color: #9a9a9a;
  --meta-subtle-color: #929292;
  --link-color: #4db89b;
  --link-missing-color: #d3b45a;
  --link-invalid-color: #f08080;
  --highlight-color: #5d4d7a;

  --top-color: #b2b2b2;
  --top-background-color: #242428;
  --top-border-color: #414047;
  --top-saved-color: #9a9a9a;
  --top-unsaved-color: #bc6ec5;
  --top-loading-color: #9a9a9a;
  --top-sync-error-color: #f08080;
  --top-sync-error-background-color: #472b30;
  --panel-background-color: #242428;
  --panel-border-color: #414047;
  --bhs-background-color: #242428;
  --bhs-border-color: #414047;
  --action-button-color: #9a9a9a;
  --action-button-hover-color: #bc6ec5;
  --action-button-active-color: #bc6ec5;

  --modal-color: #b2b2b2;
  --modal-background-color: #242428;
  --modal-border-color: #414047;
  --modal-backdrop-color: #00000066;
  --modal-help-background-color: #292b2e;
  --modal-help-color: #9a9a9a;
  --modal-selected-option-background-color: #444155;
  --modal-selected-option-color: #e0d6e5;
  --modal-description-color: #9a9a9a;
  --modal-selected-option-description-color: #cbc1d5;
  --modal-hint-background-color: #5d4d7a;
  --modal-hint-color: #ffffff;
  --modal-hint-inactive-background-color: #34323b;
  --modal-hint-inactive-color: #b2b2b2;
  --notifications-background-color: #242428;
  --notifications-border-color: #414047;
  --button-background-color: #34323b;
  --button-hover-background-color: #444155;
  --button-color: #cbc1d5;
  --button-border-color: #5d4d7a;
  --text-field-background-color: #292b2e;
  --badge-background-color: #34323b;
  --badge-color: #cbc1d5;
  --progress-background-color: #414047;
  --progress-sync-color: #4db89b;
  --progress-index-color: #bc6ec5;

  --editor-caret-color: #cbc1d5;
  --editor-selection-background-color: #444155;
  --editor-heading-color: #cbc1d5;
  --editor-heading-meta-color: #929292;
  --editor-list-bullet-color: #9a9a9a;
  --editor-ruler-color: #414047;
  --editor-wiki-link-page-background-color: transparent;
  --editor-wiki-link-color: #929292;
  --editor-code-color: #cbc1d5;
  --editor-code-background-color: #242428;
  --editor-code-comment-color: #929292;
  --editor-code-variable-color: #b2b2b2;
  --editor-code-typename-color: #4f97d7;
  --editor-code-string-color: #4db89b;
  --editor-code-number-color: #bc6ec5;
  --editor-code-operator-color: #b2b2b2;
  --editor-code-atom-color: #bc6ec5;
  --editor-code-info-color: #9a9a9a;
  --editor-struct-color: #4f97d7;
  --editor-blockquote-background-color: #242428;
  --editor-blockquote-color: #b2b2b2;
  --editor-blockquote-border-color: #5d4d7a;
  --editor-comment-background-color: #242428;
  --editor-comment-border-color: #414047;
  --editor-table-head-background-color: #34323b;
  --editor-table-head-color: #cbc1d5;
  --editor-table-even-background-color: #242428;
  --editor-frontmatter-background-color: #242428;
  --editor-frontmatter-color: #9a9a9a;
  --editor-frontmatter-marker-color: #929292;
  --editor-widget-background-color: #242428;
  --editor-widget-border-color: #414047;
  --editor-hashtag-background-color: #34323b;
  --editor-hashtag-color: #cbc1d5;
  --editor-hashtag-border-color: #5d4d7a;
  --editor-at-mention-color: #4db89b;
  --editor-at-mention-signature-color: #9a9a9a;
  --editor-at-mention-background-color: #243b35;
  --editor-at-mention-border-color: #2d9574;
  --editor-command-button-color: #cbc1d5;
  --editor-command-button-background-color: #34323b;
  --editor-command-button-hover-background-color: #444155;
  --editor-command-button-border-color: #5d4d7a;
  --editor-directive-mark-color: #929292;
  --editor-directive-color: #9a9a9a;
  --editor-directive-background-color: #242428;
  --editor-panels-bottom-color: #b2b2b2;
  --editor-panels-bottom-background-color: #292b2e;
  --editor-panels-bottom-border-color: #414047;
  --editor-panels-bottom-input-background-color: #242428;
  --editor-panels-bottom-button-background-image: none;
  --editor-panels-bottom-button-active-background-image: none;
  --editor-completion-detail-color: #9a9a9a;
  --editor-completion-detail-selected-color: #cbc1d5;

  --danger-color: #f08080;
  --success-color: #86b85c;
  --alert-error-background-color: #472b30;
  --alert-error-color: #f08080;
  --alert-error-border-color: #80515b;
  --alert-warning-background-color: #403a2b;
  --alert-warning-color: #d3b45a;
  --alert-warning-border-color: #73623d;
  --alert-info-background-color: #283645;
  --alert-info-color: #7cb2e2;
  --alert-info-border-color: #4f7090;
}

#sb-main .cm-editor {
  font-size: 18px;
}

#sb-main .cm-editor .cm-scroller {
  font-family: var(--editor-font);
  line-height: 1.7;
}

#sb-main .cm-editor .cm-content {
  box-sizing: border-box;
  padding: 1.5rem clamp(1.25rem, 4vw, 2.5rem) 4rem;
}

/* Keep line-box padding in CodeMirror's variable, preserving quote geometry. */
#sb-main .cm-editor .cm-line:is(
  .sb-line-h1, .sb-line-h2, .sb-line-h3,
  .sb-line-h4, .sb-line-h5, .sb-line-h6
) {
  --sb-line-pad-y: 0.3em;
  font-weight: 600;
}

#sb-main .cm-editor .sb-line-h1 {
  color: #bc6ec5;
  font-size: 1.65em;
}

#sb-main .cm-editor :is(.sb-line-h2, .sb-line-h3) {
  color: #cbc1d5;
}

#sb-main .cm-editor :is(
  .sb-line-code, .sb-line-fenced-code, .sb-line-code-outside,
  .sb-line-frontmatter, .sb-line-frontmatter-outside,
  .sb-code, code, pre, tt
) {
  font-family: var(--editor-monospace-font);
}

#sb-main .cm-editor :is(.sb-line-code, .sb-line-fenced-code) {
  line-height: 1.5;
}

#sb-main .cm-editor :is(.sb-wiki-link, .sb-link, .sb-naked-url, a) {
  text-underline-offset: 0.18em;
  text-decoration-thickness: 1px;
}

#sb-main .cm-editor :is(.sb-wiki-link, .sb-link, .sb-naked-url, a):hover {
  text-decoration-line: underline;
}

/* Restyle the Vim command area without hiding controls or changing keymaps. */
#sb-main .cm-editor .cm-panels-bottom .cm-vim-panel {
  font-family: var(--editor-monospace-font);
  font-size: 0.8rem;
}

@media (max-width: 600px) {
  #sb-main .cm-editor {
    font-size: 17px;
  }
}
```