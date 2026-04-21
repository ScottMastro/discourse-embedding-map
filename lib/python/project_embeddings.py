#!/usr/bin/env python3
"""
Project topic embeddings from pgvector to 2D using UMAP and write the result
back to ai_topic_projections.

Invoked from lib/tasks/embedding_map.rake, which passes DB connection info and
UMAP hyperparameters via environment variables. Never call this directly from
user-facing code paths — it is a batch tool.
"""
import json
import os
import sys
import time

import numpy as np
import psycopg
import umap


def log(msg):
    print(f"[embedding_map] {msg}", flush=True)


def load_embeddings(conn, model_id, max_points):
    # Pull the newest `max_points` topics that have an embedding under the
    # active model. Halfvec comes back as a string like "[0.1,0.2,...]"; cast
    # in-DB to text and parse on the Python side.
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT te.topic_id, te.embeddings::text
            FROM ai_topics_embeddings te
            JOIN topics t ON t.id = te.topic_id
            WHERE te.model_id = %s
              AND t.deleted_at IS NULL
              AND t.archetype = 'regular'
              AND t.visible = TRUE
            ORDER BY t.created_at DESC
            LIMIT %s
            """,
            (model_id, max_points),
        )
        rows = cur.fetchall()

    if not rows:
        return np.array([]), np.array([])

    topic_ids = np.fromiter((r[0] for r in rows), dtype=np.int64, count=len(rows))
    vectors = np.array(
        [json.loads(r[1]) for r in rows],
        dtype=np.float32,
    )
    return topic_ids, vectors


def write_projections(conn, model_id, topic_ids, coords):
    rows = [
        (int(topic_ids[i]), float(coords[i, 0]), float(coords[i, 1]), model_id)
        for i in range(len(topic_ids))
    ]

    with conn.cursor() as cur:
        # Clear previous run for this model, then bulk-insert. A full replace
        # is simpler than row-by-row upsert and the table is small (≤ max_points).
        cur.execute("DELETE FROM ai_topic_projections WHERE model_id = %s", (model_id,))
        cur.executemany(
            """
            INSERT INTO ai_topic_projections (topic_id, x, y, model_id, method, computed_at)
            VALUES (%s, %s, %s, %s, 'umap', NOW())
            ON CONFLICT (topic_id) DO UPDATE
              SET x = EXCLUDED.x,
                  y = EXCLUDED.y,
                  model_id = EXCLUDED.model_id,
                  computed_at = EXCLUDED.computed_at
            """,
            rows,
        )
    conn.commit()


def main():
    dsn = os.environ["EMBEDDING_MAP_DSN"]
    model_id = int(os.environ["EMBEDDING_MAP_MODEL_ID"])
    max_points = int(os.environ.get("EMBEDDING_MAP_MAX_POINTS", "50000"))
    n_neighbors = int(os.environ.get("EMBEDDING_MAP_N_NEIGHBORS", "15"))
    min_dist = float(os.environ.get("EMBEDDING_MAP_MIN_DIST", "0.1"))

    with psycopg.connect(dsn) as conn:
        log(f"loading embeddings (model_id={model_id}, max={max_points})")
        t0 = time.time()
        topic_ids, vectors = load_embeddings(conn, model_id, max_points)
        log(f"loaded {len(topic_ids)} vectors in {time.time() - t0:.1f}s")

        if len(topic_ids) < 2:
            log("not enough vectors to project; aborting")
            sys.exit(1)

        log(f"running UMAP (n_neighbors={n_neighbors}, min_dist={min_dist})")
        t0 = time.time()
        reducer = umap.UMAP(
            n_components=2,
            n_neighbors=n_neighbors,
            min_dist=min_dist,
            metric="cosine",
            random_state=42,
        )
        coords = reducer.fit_transform(vectors)
        log(f"UMAP completed in {time.time() - t0:.1f}s")

        log("writing projections to DB")
        write_projections(conn, model_id, topic_ids, coords)
        log(f"wrote {len(topic_ids)} rows")


if __name__ == "__main__":
    main()
