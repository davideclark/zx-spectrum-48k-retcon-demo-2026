# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`retcon` is a semantic search data package — a configuration, model, and vector database bundle for the Spectrum project. It contains no application source code of its own; it is consumed by a host application that performs document embedding and retrieval.

## Architecture

```
documents/           ← drop documents here to be indexed
config.json          ← controls chunking, model, DB path, and search params
models/
  multilingual-e5-small/   ← local ONNX embedding model (384-dim, multilingual)
vectors.db           ← SQLite vector database populated by the indexer
```

**Data flow:**
1. Documents placed in `documents/` are chunked (500 tokens each) and embedded by the host application using the bundled ONNX model.
2. Embeddings are stored in `vectors.db`.
3. Queries are embedded the same way; the top-5 nearest neighbours are retrieved from `vectors.db`.

## Configuration (`config.json`)

| Key | Default | Purpose |
|-----|---------|---------|
| `document_patterns` | `["./documents"]` | Directories scanned for documents to index |
| `db_path` | `./vectors.db` | SQLite database for vector storage |
| `chunk_size` | `500` | Tokens per document chunk |
| `search_top_k` | `5` | Number of results returned per query |
| `compute.device` | `"auto"` | Inference device; falls back to CPU automatically |
| `model.name` | `multilingual-e5-small` | Model directory name under `models/` |
| `model.dimensions` | `384` | Output embedding dimensionality |

## Model

`models/multilingual-e5-small` is a locally bundled copy of the `multilingual-e5-small` HuggingFace model in ONNX format. It uses an XLMRoberta tokenizer and supports 100+ languages. The model files (~488 MB total) must not be committed to git if the repo uses LFS or size limits — verify before adding new model variants.
