# discourse-embedding-map

Interactive 2D map of topic embeddings. UMAP-reduces the vectors produced by
the Discourse AI embeddings pipeline into `(x, y)` coordinates and renders them
in a WebGL scatterplot at `/topic-map`. Hover for titles, click to open the
topic, colors by category.

## Rebuilding the scatterplot bundle

The WebGL library `regl-scatterplot` is pre-bundled into
`public/javascripts/regl-scatterplot.bundle.js` (committed to the repo) so
Discourse's plugin build doesn't need to resolve npm deps. To rebuild after
upgrading:

```
cd plugins/discourse-embedding-map
npm install
npm run build
```

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
task reads the active embedding model from `ai_embeddings_selected_model` and
writes to `ai_topic_projections`.

## Settings

- `embedding_map_enabled` — master switch.
- `embedding_map_min_trust_level` — gate the page. `-1` allows anonymous.
- `embedding_map_max_points` — cap; newest topics are kept when over.
- `embedding_map_umap_n_neighbors`, `embedding_map_umap_min_dist` — UMAP
  hyperparameters.

## Access control

Category permissions are respected per-request via `Category.secured(guardian)`
— the JSON payload never includes topics in categories the user can't see.
