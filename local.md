# Project overview

AI-powered Q&A system for Korean web novel authors. Authors upload manuscript chapters;
the pipeline splits them into scenes, builds a hierarchical summary tree, and indexes into
Qdrant. A QA loop (Claude Sonnet 4.6 + tool use) answers author questions with citations
against the live tree or its archive.

# Language and runtime

- Language: Python
- Version: 3.12 (backend), TypeScript (frontend)
- Package manager: uv (Python), pnpm (frontend)
- Framework: FastAPI (async), SvelteKit

# Shell commands

- Test: `pytest`
- Lint: `ruff check .`
- Build: `pnpm build`
- Integration test: `pytest tests/integration`

# Domain vocabulary

| Term | Definition |
|------|-----------|
| scene | Atomic narrative unit within a chapter; basic storage and retrieval unit |
| tree_node | Node in the hierarchical summary tree; leaf = scene, internal = compressed summary |
| chapter_order | Immutable integer assigned at upload time; ordering key for chapters |
