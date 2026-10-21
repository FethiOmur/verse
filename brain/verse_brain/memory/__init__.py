"""Verse memory: a local SQLite index (FTS5 + EmbeddingGemma vectors) over the text of past sessions and the search on it.

`index` owns the file, the schema and the chunking; `search` the hybrid retrieval, the excerpt rendering and the citation
check; `indexer` the `memory_index_start` mode of `python -u -m verse_brain.runtime`. Spec: docs/specs/2026-10-21-verse-memory-package-design.md.
"""
