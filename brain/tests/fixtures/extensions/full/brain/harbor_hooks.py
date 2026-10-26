"""A fictional extension that uses every hook. Test fixture only."""

from pathlib import Path

HERE = Path(__file__).resolve().parent


class HarborVault:
    """Answers every query with the same fictional record; remembers how it was bound."""

    def __init__(self, vault_path=None, audience="internal"):
        self.vault_path = vault_path
        self.audience = audience

    def bind(self, vault_path, audience):
        return HarborVault(vault_path, audience)

    def search(self, query, limit=3, budget_chars=2500):
        text = f"Harbor note for {query} (audience {self.audience})"
        return [{"id": "h-1", "source": "Harbor/Quay.md", "text": text},
                {"id": "h-2", "source": "Harbor/Pier.md", "text": "second"},
                {"id": "h-3", "source": "", "text": "no source, dropped"}][:limit]


def register(registry):
    registry.set_vault_provider(HarborVault())
    registry.add_profile_source(HERE.parent / "harbor-profile.md")
    registry.add_prompt_addendum("prep", "HARBOR-ADDENDUM-PREP for {owner}.")
    registry.add_prompt_addendum("live_fast", "HARBOR-ADDENDUM-FAST.")
    registry.add_prompt_addendum("live_deep", "HARBOR-ADDENDUM-DEEP.")
    registry.add_prompt_addendum("profile", "HARBOR-ADDENDUM-PROFILE.")
    registry.add_prompt_addendum("voice", "HARBOR-ADDENDUM-VOICE.")
    registry.add_prompt_addendum("script", "HARBOR-ADDENDUM-SCRIPT.")
    registry.add_prompt_addendum("ask", "HARBOR-ADDENDUM-ASK for {owner}.")
    registry.add_prompt_addendum("memory_ask", "HARBOR-ADDENDUM-MEMORY-ASK for {owner}.")
    registry.add_prompt_addendum("brief", "HARBOR-ADDENDUM-BRIEF.")
    registry.add_private_project("Lighthouse-Private")
    assert registry.config.get("harbor_setting") == "on"      # the extension reads its own key from the owner file
