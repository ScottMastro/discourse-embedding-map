# discourse-embedding-map

Interactive 2D map of topic embeddings. UMAP-reduces the vectors produced by
the Discourse AI embeddings pipeline into `(x, y)` coordinates and renders them
in a WebGL scatterplot at `/topic-map`. Hover for titles, click to open the
topic, colors by category.

## Setup

Requires Python 3 on the host with:

```
pip install -r plugins/discourse-embedding-map/lib/python/requirements.txt
```

Then compute the projection:

```
bundle exec rake embedding_map:compute
```

Re-run whenever you want the map refreshed against the latest embeddings. The
task reads the active embedding model from `ai_embeddings_selected_model`,
writes 2D coordinates to `ai_topic_projections`, and writes HDBSCAN cluster
assignments + c-TF-IDF keywords to `ai_topic_clusters`. Set
`EMBEDDING_MAP_SKIP_CLUSTERING=1` to skip the clustering pass.

## Settings

- `embedding_map_enabled` — master switch.
- `embedding_map_min_trust_level` — gate the page. `-1` allows anonymous.
- `embedding_map_max_points` — cap; newest topics are kept when over.
- `embedding_map_umap_n_neighbors`, `embedding_map_umap_min_dist` — UMAP
  hyperparameters.

## Access control

Category permissions are respected per-request via `Category.secured(guardian)`
— the JSON payload never includes topics in categories the user can't see.
