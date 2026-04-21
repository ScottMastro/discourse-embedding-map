#!/usr/bin/env python3
"""
Project topic embeddings to 2D (UMAP) and cluster them (HDBSCAN on a separate
5D UMAP pass). Writes coordinates back to ai_topic_projections and cluster
metadata (size, centroid, keywords) to ai_topic_clusters.

Invoked from lib/tasks/embedding_map.rake, which passes DB connection info and
hyperparameters via environment variables. Never call this directly from
user-facing code paths — it is a batch tool.
"""
import json
import math
import os
import re
import sys
import time
from collections import Counter, defaultdict

import numpy as np
import psycopg
import umap

SKIP_CLUSTERING = os.environ.get("EMBEDDING_MAP_SKIP_CLUSTERING") == "1"

# Minimal English stopword list — good enough for forum title keywording.
STOPWORDS = frozenset("""
a an the and or but if then else of at by for in on to from with without about
into over under again further more most some any all no not only own same so
than too very can will just should now is are was were be been being have has
had do does did doing this that these those i me my we our you your he she it
its they them their what which who whom whose when where why how as also if
because until while before after during through against between up down out
off above below here there why how s t d ll m o re ve y what's that's etc
get got use using used say saying said new old still also vs don
""".split())

TOKEN_RE = re.compile(r"\b[a-z][a-z0-9']{2,}\b")


def log(msg):
    print(f"[embedding_map] {msg}", flush=True)


def load_embeddings(conn, model_id, max_points):
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT te.topic_id, te.embeddings::text, t.title
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
        return np.array([]), np.array([]), []

    topic_ids = np.fromiter((r[0] for r in rows), dtype=np.int64, count=len(rows))
    vectors = np.array([json.loads(r[1]) for r in rows], dtype=np.float32)
    titles = [r[2] or "" for r in rows]
    return topic_ids, vectors, titles


def run_umap(vectors, n_components, n_neighbors, min_dist, label):
    log(f"UMAP → {n_components}D (n_neighbors={n_neighbors}, min_dist={min_dist}) [{label}]")
    t0 = time.time()
    reducer = umap.UMAP(
        n_components=n_components,
        n_neighbors=n_neighbors,
        min_dist=min_dist,
        metric="cosine",
        random_state=42,
    )
    out = reducer.fit_transform(vectors)
    log(f"UMAP {label} completed in {time.time() - t0:.1f}s")
    return out


def run_hdbscan(vectors_5d):
    import hdbscan

    n = len(vectors_5d)
    min_cluster_size = max(20, n // 500)
    log(f"HDBSCAN (min_cluster_size={min_cluster_size}) on {n} points")
    t0 = time.time()
    clusterer = hdbscan.HDBSCAN(
        min_cluster_size=min_cluster_size,
        min_samples=5,
        metric="euclidean",
        cluster_selection_method="eom",
    )
    labels = clusterer.fit_predict(vectors_5d)
    n_clusters = int(labels.max()) + 1 if (labels >= 0).any() else 0
    n_noise = int((labels == -1).sum())
    log(f"HDBSCAN found {n_clusters} clusters ({n_noise} noise) in {time.time() - t0:.1f}s")
    return labels


def tokenize(text):
    return [t for t in TOKEN_RE.findall(text.lower()) if t not in STOPWORDS]


def extract_keywords(labels, titles, top_k=5):
    """c-TF-IDF: each cluster is one document, compare against the corpus."""
    by_cluster = defaultdict(list)
    for idx, cluster in enumerate(labels):
        if cluster >= 0:
            by_cluster[int(cluster)].append(titles[idx])

    # Per-cluster term counts.
    cluster_terms = {c: Counter() for c in by_cluster}
    for c, docs in by_cluster.items():
        for doc in docs:
            cluster_terms[c].update(tokenize(doc))

    # Corpus: number of clusters each term appears in.
    term_cluster_count = Counter()
    for c, counts in cluster_terms.items():
        for term in counts:
            term_cluster_count[term] += 1

    n_clusters = len(cluster_terms)
    keywords = {}
    for c, counts in cluster_terms.items():
        total = sum(counts.values()) or 1
        scored = []
        for term, count in counts.items():
            tf = count / total
            # Log-scale IDF against the number of *clusters* — BERTopic-style.
            df = term_cluster_count[term]
            idf = math.log(1 + n_clusters / df)
            scored.append((term, tf * idf))
        scored.sort(key=lambda x: x[1], reverse=True)
        keywords[c] = [term for term, _ in scored[:top_k]]
    return keywords


def write_projections(conn, model_id, topic_ids, coords, cluster_labels):
    """cluster_labels can be None (skipped) or an ndarray aligned with topic_ids."""
    rows = []
    for i in range(len(topic_ids)):
        if cluster_labels is None:
            cluster_idx = None
        else:
            raw = int(cluster_labels[i])
            cluster_idx = None if raw < 0 else raw
        rows.append(
            (
                int(topic_ids[i]),
                float(coords[i, 0]),
                float(coords[i, 1]),
                model_id,
                cluster_idx,
            )
        )

    with conn.cursor() as cur:
        cur.execute("DELETE FROM ai_topic_projections WHERE model_id = %s", (model_id,))
        cur.executemany(
            """
            INSERT INTO ai_topic_projections
              (topic_id, x, y, model_id, cluster_idx, method, computed_at)
            VALUES (%s, %s, %s, %s, %s, 'umap', NOW())
            ON CONFLICT (topic_id) DO UPDATE
              SET x = EXCLUDED.x,
                  y = EXCLUDED.y,
                  model_id = EXCLUDED.model_id,
                  cluster_idx = EXCLUDED.cluster_idx,
                  computed_at = EXCLUDED.computed_at
            """,
            rows,
        )
    conn.commit()


def write_clusters(conn, model_id, cluster_labels, coords_2d, keywords):
    if cluster_labels is None:
        return

    by_cluster = defaultdict(list)
    for i, c in enumerate(cluster_labels):
        if c >= 0:
            by_cluster[int(c)].append(i)

    rows = []
    for c, idxs in by_cluster.items():
        pts = coords_2d[idxs]
        rows.append(
            (
                model_id,
                c,
                len(idxs),
                float(pts[:, 0].mean()),
                float(pts[:, 1].mean()),
                json.dumps(keywords.get(c, [])),
            )
        )

    with conn.cursor() as cur:
        cur.execute("DELETE FROM ai_topic_clusters WHERE model_id = %s", (model_id,))
        cur.executemany(
            """
            INSERT INTO ai_topic_clusters
              (model_id, cluster_idx, size, centroid_x, centroid_y, keywords, method, computed_at)
            VALUES (%s, %s, %s, %s, %s, %s::jsonb, 'hdbscan', NOW())
            """,
            rows,
        )
    conn.commit()
    log(f"wrote {len(rows)} clusters")


def main():
    dsn = os.environ["EMBEDDING_MAP_DSN"]
    model_id = int(os.environ["EMBEDDING_MAP_MODEL_ID"])
    max_points = int(os.environ.get("EMBEDDING_MAP_MAX_POINTS", "50000"))
    n_neighbors = int(os.environ.get("EMBEDDING_MAP_N_NEIGHBORS", "15"))
    min_dist = float(os.environ.get("EMBEDDING_MAP_MIN_DIST", "0.1"))

    with psycopg.connect(dsn) as conn:
        log(f"loading embeddings (model_id={model_id}, max={max_points})")
        t0 = time.time()
        topic_ids, vectors, titles = load_embeddings(conn, model_id, max_points)
        log(f"loaded {len(topic_ids)} vectors in {time.time() - t0:.1f}s")

        if len(topic_ids) < 2:
            log("not enough vectors to project; aborting")
            sys.exit(1)

        coords_2d = run_umap(vectors, 2, n_neighbors, min_dist, "viz")

        cluster_labels = None
        keywords = {}
        if not SKIP_CLUSTERING:
            coords_5d = run_umap(vectors, 5, n_neighbors, min_dist, "cluster")
            cluster_labels = run_hdbscan(coords_5d)
            log("extracting keywords (c-TF-IDF)")
            keywords = extract_keywords(cluster_labels, titles)

        log("writing projections to DB")
        write_projections(conn, model_id, topic_ids, coords_2d, cluster_labels)
        log(f"wrote {len(topic_ids)} projection rows")

        write_clusters(conn, model_id, cluster_labels, coords_2d, keywords)


if __name__ == "__main__":
    main()
