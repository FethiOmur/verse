"""Vault retrieval in the core: the built-in markdown-folder search and the wrapper around an extension's provider.
Fictional notes only (fixtures/extensions/notes)."""

import pytest

from verse_brain import extensions
from verse_brain.prep.vault import MarkdownFolderVault, ProviderVault, VaultError, VaultRecord, make_vault

NOTES = __import__("pathlib").Path(__file__).parent / "fixtures" / "extensions" / "notes"


@pytest.fixture
def with_registry():
    def put(reg):
        extensions.set_registry(reg)
    yield put
    extensions.set_registry(None)


def test_markdown_search_ranks_by_term_hits_and_returns_relative_sources():
    recs = MarkdownFolderVault(NOTES, forbidden=["Journal"]).search("ferry timetable", limit=3)
    assert [r.source for r in recs] == ["Quay.md", "Pier/Moorings.md"]
    assert all(isinstance(r, VaultRecord) and r.text and r.record_id.startswith("md-") for r in recs)
    assert "first ferry leaves at six" in recs[0].text


def test_markdown_search_skips_hidden_and_forbidden_folders_and_abstains():
    v = MarkdownFolderVault(NOTES, forbidden=["journal"])
    assert not any(r.source.startswith((".hidden", "Journal")) for r in v.search("ferry", limit=10))
    assert any(r.source.startswith("Journal") for r in MarkdownFolderVault(NOTES, forbidden=[]).search("ferry", limit=10))
    assert v.search("zzzqqq yyyxxx", limit=3) == []          # no term matches: abstain
    assert v.search("   ") == [] and v.search("an of it") == []   # nothing but stop words / short words


def test_markdown_search_is_deterministic_and_honours_limit_and_budget():
    v = MarkdownFolderVault(NOTES, forbidden=["Journal"])
    a, b = v.search("ferry", limit=1), v.search("ferry", limit=1)
    assert a == b and len(a) == 1
    assert len(v.search("ferry", limit=2, budget_chars=400)[0].text) <= 400


def test_markdown_search_missing_folder_is_a_vault_error(tmp_path):
    with pytest.raises(VaultError):
        MarkdownFolderVault(tmp_path / "nope").search("ferry")


def test_make_vault_default_is_builtin_or_none():
    assert make_vault(None) is None
    assert isinstance(make_vault(NOTES), MarkdownFolderVault)


def test_provider_wrapper_normalises_records_and_limits():
    class P:
        def search(self, query, limit=3, budget_chars=2500):
            return [{"id": "a", "source": "X.md", "text": " body "}, {"source": "Y.md", "text": "t" * 5000},
                    {"id": "c", "source": "", "text": "dropped"}, {"id": "d", "source": "Z.md", "text": ""}]

    recs = ProviderVault(P()).search("q", limit=5)
    assert [(r.record_id, r.source) for r in recs] == [("a", "X.md"), ("Y.md", "Y.md")]
    assert recs[0].text == "body" and len(recs[1].text) == 1500
    assert len(ProviderVault(P()).search("q", limit=1)) == 1


def test_provider_wrapper_accepts_a_query_only_search_and_attribute_records():
    class Rec:
        id, source, text = "r1", "R.md", "attr text"

    class P:
        def search(self, query):
            return [Rec()]

    assert [r.record_id for r in ProviderVault(P()).search("q", limit=3, budget_chars=10)] == ["r1"]


@pytest.mark.parametrize("bad", [RuntimeError("x"), KeyError("k")])
def test_provider_failure_is_a_vault_error(bad):
    class P:
        def search(self, query, **kw):
            raise bad

    with pytest.raises(VaultError):
        ProviderVault(P()).search("q")


def test_provider_returning_no_list_is_a_vault_error():
    class P:
        def search(self, query, **kw):
            return 5

    with pytest.raises(VaultError):
        ProviderVault(P()).search("q")


def test_make_vault_uses_a_registered_provider_and_bind(with_registry, tmp_path):
    seen = {}

    class P:
        def bind(self, vault_path, audience):
            seen["args"] = (vault_path, audience)
            return self

        def search(self, query, **kw):
            return [{"id": "p", "source": "P.md", "text": "from provider"}]

    reg = extensions.Registry()
    reg.set_vault_provider(P())
    with_registry(reg)
    v = make_vault(tmp_path, audience="public")
    assert isinstance(v, ProviderVault) and v.search("q")[0].text == "from provider"
    assert seen["args"] == (tmp_path, "public")
    assert isinstance(make_vault(None), ProviderVault)         # a provider needs no vault_path


def test_provider_bind_none_means_no_retrieval_and_bind_error_falls_back(with_registry, caplog):
    class NoBind:
        def bind(self, p, a):
            return None

        def search(self, q):
            return []

    class BadBind:
        def bind(self, p, a):
            raise RuntimeError("cannot bind")

        def search(self, q):
            return []

    reg = extensions.Registry()
    reg.set_vault_provider(NoBind())
    with_registry(reg)
    assert make_vault(NOTES) is None
    reg2 = extensions.Registry()
    reg2.set_vault_provider(BadBind())
    with_registry(reg2)
    with caplog.at_level("WARNING", logger="verse.extensions"):
        assert isinstance(make_vault(NOTES), MarkdownFolderVault)
    assert len([r for r in caplog.records if r.name == "verse.extensions"]) == 1
