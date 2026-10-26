# Extensions

Verse's core is generic. If you need more than the core offers (your own retrieval over your own notes, extra files for your
profile, house rules in a prompt), keep that code in a folder of your own and tell Verse where it is. Nothing in that folder
ever has to enter this repository.

## Configure

Add one key to the owner profile, `~/Library/Application Support/Verse/owner.json` (the location can be overridden with
`VERSE_OWNER_FILE`):

```json
{ "extensions_path": "~/Verse-extensions" }
```

Verse loads Python modules from `<extensions_path>/brain/*.py`, in file-name order. Files whose names start with `_` are skipped.

- Code is loaded **only** from that folder. Never from this repository, the working directory or `sys.path`, and the folder is not
  added to `sys.path`. A module is a standalone file: it can import the standard library and `verse_brain`, not its siblings.
- The brain reads the extensions once, at start. Restart the brain (a new prep run or a new session) after changing them.
- The whole `owner.json` is passed to the modules as `registry.config`, so an extension can keep its own settings in the same file
  next to the core keys.

## A module

A module exposes `register(registry)` and calls the hooks it needs:

```python
def register(registry):
    registry.add_prompt_addendum("prep", "Keep answers under two sentences, {owner}.")
    registry.add_private_project("Client-X")
```

## The hooks

| Hook | Call | Effect |
|---|---|---|
| Vault provider | `registry.set_vault_provider(provider)` | Replaces the built-in vault search at prep. |
| Profile sources | `registry.add_profile_source(path)` | Adds a file to the first-build sources of the me profile (if it exists). |
| Prompt addenda | `registry.add_prompt_addendum(name, text)` | Appends a text block to the named system prompt. |
| Private projects | `registry.add_private_project(name)` | A project folder that is never read into the profile. |

### Vault provider

The core ships a plain keyword search over the markdown files of `vault_path` (`MarkdownFolderVault`; hidden folders,
`forbidden_vault_folders` and private project folders are skipped). Without `vault_path` there is no retrieval. A provider
replaces it:

```python
class MyVault:
    def bind(self, vault_path, audience):            # optional: called once per prep run
        return self                                   # return None to switch retrieval off
    def search(self, query, limit=3, budget_chars=2500):
        return [{"id": "n1", "source": "Projects/Alpha.md", "text": "..."}]
```

`search` may take just `query`; `limit` and `budget_chars` are passed only if it accepts them. A record is a dict (or an object)
with `id`, `source` (a vault-relative path, shown to the model as `vault:<source>`) and `text` (cut to 1500 characters). Records
without `source` or `text` are dropped. Any exception becomes a warning for that query; prep goes on with the other sources.
Retrieval is for prep only. Keep a provider read-only.

**What is never returned.** The core drops every record whose `source` lies under a forbidden vault folder
(`forbidden_vault_folders`) or under a private project folder (`<projects_folder>/<name>`, where the name comes from
`private_project_folders` or `registry.add_private_project`), whichever vault produced it, so a provider cannot leak them. The
check ignores case, `\` versus `/`, `.` and `..`. The private project list is read when a search runs, not at import.

**The `public` audience is safe by default.** Only `internal` gets every allowed note.

- The built-in search, for any other audience, returns only notes whose frontmatter says `visibility: public`
  (`---` block at the very top of the file; a note without it, or with another value, is never returned).
- A provider is trusted to enforce the audience only if it defines `bind(vault_path, audience)`. A provider without `bind` gets
  no vault for the public audience (a warning is logged and retrieval is off). If `bind` raises, the built-in search is used,
  with the same public-only rule.

### Prompt addenda

`name` is one of: `prep`, `profile`, `voice`, `script`, `live_fast`, `live_deep`, `ask`, `memory_ask`, `brief`. The block is appended after the prompt
text, separated by a blank line. `{owner}`, `{Owner}` and `{OWNER}` are replaced by the owner's display name. Prompts are cache
prefixes: they are built once at start, so an addendum cannot change inside a run.

### Private projects and profile sources

Both feed the me-profile build (`python -m verse_brain.prep me build`). Private project names are added to
`private_project_folders` from the owner profile. They are read when they are used, so an extension that imports core
modules while it is loading cannot make the list come out empty: while the extensions load, `registry()` logs a warning and
the private project list refuses to answer. Profile sources are listed only when the sources file does not exist yet (a
first build); later changes go through the me page or `me.sources.json`.

## Failure behaviour

Extensions never stop the brain. In each case below one warning is logged on the `verse.extensions` logger (stderr) and the core
behaviour stays:

- the folder in `extensions_path` does not exist or cannot be read;
- a module fails to import, has no `register`, raises (or calls `sys.exit`) inside it, or passes an invalid value to a hook. A
  module that fails contributes nothing, including what it registered before it failed; the other modules still load;
- a second vault provider (the first one wins);
- a provider's `bind` raises (the built-in search is used).

## Testing an extension

Load it the way Verse does and look at the registry:

```python
from verse_brain.extensions import load_extensions
reg = load_extensions("~/Verse-extensions", config={})
assert reg.vault_provider is not None
```

Run it with the brain's interpreter (`brain/.venv/bin/python`).
