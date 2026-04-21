import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import { i18n } from "discourse-i18n";

// Index format (matches controller serialization):
//   [topic_id, x, y, category_id, created_at_epoch, slug, title, cluster_idx]
const TOPIC_ID = 0;
const X = 1;
const Y = 2;
const CATEGORY_ID = 3;
const SLUG = 5;
const TITLE = 6;
const CLUSTER_IDX = 7;

const POINT_SIZE = 3;
const HOVER_RADIUS_PX = 6;
const GRID_CELLS = 128;

// Deterministic palette for cluster view. 20 colors cycled by cluster_idx.
const CLUSTER_PALETTE = [
  "#e6194b",
  "#3cb44b",
  "#ffe119",
  "#4363d8",
  "#f58231",
  "#911eb4",
  "#42d4f4",
  "#f032e6",
  "#bfef45",
  "#fabed4",
  "#469990",
  "#dcbeff",
  "#9a6324",
  "#800000",
  "#aaffc3",
  "#808000",
  "#ffd8b1",
  "#000075",
  "#a9a9a9",
  "#ff4500",
];
const NOISE_COLOR = "#cccccc";

export default class EmbeddingMapViewer extends Component {
  @service router;

  @tracked viewMode = "category";
  @tracked hoveredTitle = null;
  @tracked hoveredClusterIdx = null;
  @tracked hoverX = 0;
  @tracked hoverY = 0;
  @tracked query = "";

  canvas = null;
  ctx = null;
  resizeObserver = null;

  minX = 0;
  maxX = 0;
  minY = 0;
  maxY = 0;

  scale = 1;
  offsetX = 0;
  offsetY = 0;

  dragging = false;
  lastPointerX = 0;
  lastPointerY = 0;
  dragMoved = false;

  spatialGrid = null;

  get points() {
    return this.args.data?.points ?? [];
  }

  get categories() {
    return this.args.data?.categories ?? [];
  }

  get clusters() {
    return this.args.data?.clusters ?? [];
  }

  get visiblePointCount() {
    return this.points.length;
  }

  get categoryColorMap() {
    const map = new Map();
    for (const c of this.categories) {
      map.set(c.id, c.color ? `#${c.color}` : "#888888");
    }
    return map;
  }

  get clusterColorFor() {
    return (idx) => {
      if (idx === null || idx === undefined || idx < 0) {
        return NOISE_COLOR;
      }
      return CLUSTER_PALETTE[idx % CLUSTER_PALETTE.length];
    };
  }

  get isClusterView() {
    return this.viewMode === "clusters";
  }

  get isCategoryView() {
    return this.viewMode === "category";
  }

  // Clusters above this size get a label drawn on the canvas. Smaller clusters
  // stay colored but unlabeled to keep the overlay readable.
  get labeledClusters() {
    return this.clusters.filter((c) => c.size >= 20);
  }

  get legendEntries() {
    if (this.isClusterView) {
      return this.clusters.map((c) => ({
        id: `cluster-${c.idx}`,
        color: this.clusterColorFor(c.idx).slice(1),
        name:
          c.label || c.keywords?.slice(0, 3).join(", ") || `Cluster ${c.idx}`,
        size: c.size,
      }));
    }
    return this.categories.map((c) => ({
      id: `category-${c.id}`,
      color: c.color || "888",
      name: c.name,
      size: null,
    }));
  }

  @action
  setup(element) {
    this.canvas = element;
    this.ctx = element.getContext("2d");
    this.fitBounds();
    this.buildSpatialGrid();
    this.resizeCanvas();
    this.draw();

    this.resizeObserver = new ResizeObserver(() => {
      this.resizeCanvas();
      this.draw();
    });
    this.resizeObserver.observe(element.parentElement);
  }

  @action
  teardown() {
    this.resizeObserver?.disconnect();
  }

  fitBounds() {
    const { points } = this;
    if (!points.length) {
      return;
    }
    let xMin = Infinity;
    let xMax = -Infinity;
    let yMin = Infinity;
    let yMax = -Infinity;
    for (const p of points) {
      const x = p[X];
      const y = p[Y];
      if (x < xMin) {
        xMin = x;
      }
      if (x > xMax) {
        xMax = x;
      }
      if (y < yMin) {
        yMin = y;
      }
      if (y > yMax) {
        yMax = y;
      }
    }
    this.minX = xMin;
    this.maxX = xMax;
    this.minY = yMin;
    this.maxY = yMax;
  }

  buildSpatialGrid() {
    const grid = new Array(GRID_CELLS * GRID_CELLS);
    const { points, minX, maxX, minY, maxY } = this;
    const xRange = maxX - minX || 1;
    const yRange = maxY - minY || 1;

    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const col = Math.min(
        GRID_CELLS - 1,
        Math.floor(((p[X] - minX) / xRange) * GRID_CELLS)
      );
      const row = Math.min(
        GRID_CELLS - 1,
        Math.floor(((p[Y] - minY) / yRange) * GRID_CELLS)
      );
      const key = row * GRID_CELLS + col;
      (grid[key] ||= []).push(i);
    }
    this.spatialGrid = grid;
  }

  resizeCanvas() {
    const wrapper = this.canvas.parentElement;
    const rect = wrapper.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const cssW = rect.width || 800;
    const cssH = rect.height || 600;
    this.canvas.width = cssW * dpr;
    this.canvas.height = cssH * dpr;
    this.canvas.style.width = `${cssW}px`;
    this.canvas.style.height = `${cssH}px`;
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    const pad = 0.05;
    const xRange = (this.maxX - this.minX) * (1 + 2 * pad) || 1;
    const yRange = (this.maxY - this.minY) * (1 + 2 * pad) || 1;
    this.scale = Math.min(cssW / xRange, cssH / yRange);
    const worldMidX = (this.minX + this.maxX) / 2;
    const worldMidY = (this.minY + this.maxY) / 2;
    this.offsetX = cssW / 2 - worldMidX * this.scale;
    this.offsetY = cssH / 2 - worldMidY * this.scale;
  }

  colorForPoint(p) {
    if (this.isClusterView) {
      return this.clusterColorFor(p[CLUSTER_IDX]);
    }
    return this.categoryColorMap.get(p[CATEGORY_ID]) ?? "#888888";
  }

  draw() {
    if (!this.ctx || !this.canvas) {
      return;
    }
    const ctx = this.ctx;
    const dpr = window.devicePixelRatio || 1;
    const cssW = this.canvas.width / dpr;
    const cssH = this.canvas.height / dpr;

    ctx.clearRect(0, 0, cssW, cssH);

    const { points } = this;
    const size = POINT_SIZE;
    const half = size / 2;

    // Bucket by color to minimize fillStyle changes. In cluster view this also
    // naturally lets us draw noise first (underneath the real clusters).
    const buckets = new Map();
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const color = this.colorForPoint(p);
      let list = buckets.get(color);
      if (!list) {
        list = [];
        buckets.set(color, list);
      }
      list.push(p);
    }

    // Draw noise first so it doesn't sit on top of real clusters.
    const noiseFirst = [...buckets].sort(([a], [b]) => {
      if (a === NOISE_COLOR) {
        return -1;
      }
      if (b === NOISE_COLOR) {
        return 1;
      }
      return 0;
    });

    for (const [color, list] of noiseFirst) {
      ctx.globalAlpha = color === NOISE_COLOR ? 0.35 : 0.85;
      ctx.fillStyle = color;
      for (const p of list) {
        const sx = p[X] * this.scale + this.offsetX;
        const sy = p[Y] * this.scale + this.offsetY;
        ctx.fillRect(sx - half, sy - half, size, size);
      }
    }
    ctx.globalAlpha = 1;

    if (this.isClusterView) {
      this.drawClusterLabels();
    }
  }

  drawClusterLabels() {
    const ctx = this.ctx;
    const hoveredIdx = this.hoveredClusterIdx;

    // The hovered cluster may be unlabeled (size < 20) but we still want to
    // call it out, so merge it into the draw set and render it last so it
    // paints on top of any neighbors.
    const toDraw = [...this.labeledClusters];
    const hoveredCluster =
      hoveredIdx !== null && hoveredIdx !== undefined
        ? this.clusters.find((c) => c.idx === hoveredIdx)
        : null;
    if (hoveredCluster && !toDraw.includes(hoveredCluster)) {
      toDraw.push(hoveredCluster);
    }
    if (hoveredCluster) {
      const i = toDraw.indexOf(hoveredCluster);
      if (i >= 0 && i !== toDraw.length - 1) {
        toDraw.splice(i, 1);
        toDraw.push(hoveredCluster);
      }
    }

    for (const c of toDraw) {
      const isHovered = hoveredCluster === c;
      const sx = c.cx * this.scale + this.offsetX;
      const sy = c.cy * this.scale + this.offsetY;
      const text = c.label || c.keywords?.slice(0, 2).join(", ");
      if (!text) {
        continue;
      }

      ctx.font = isHovered
        ? "bold 14px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
        : "12px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";

      const metrics = ctx.measureText(text);
      const padX = isHovered ? 8 : 6;
      const w = metrics.width + padX * 2;
      const h = isHovered ? 22 : 18;

      ctx.fillStyle = isHovered ? "#fffbe6" : "rgba(255, 255, 255, 0.85)";
      ctx.fillRect(sx - w / 2, sy - h / 2, w, h);
      ctx.strokeStyle = isHovered
        ? this.clusterColorFor(c.idx)
        : "rgba(0, 0, 0, 0.15)";
      ctx.lineWidth = isHovered ? 2 : 1;
      ctx.strokeRect(sx - w / 2, sy - h / 2, w, h);

      ctx.fillStyle = isHovered ? "#000" : "#333";
      ctx.fillText(text, sx, sy + 1);
    }
    ctx.lineWidth = 1;
  }

  screenToWorld(sx, sy) {
    return {
      x: (sx - this.offsetX) / this.scale,
      y: (sy - this.offsetY) / this.scale,
    };
  }

  findNearest(worldX, worldY, maxWorldDist) {
    const grid = this.spatialGrid;
    if (!grid) {
      return -1;
    }
    const xRange = this.maxX - this.minX || 1;
    const yRange = this.maxY - this.minY || 1;
    const col = Math.min(
      GRID_CELLS - 1,
      Math.max(0, Math.floor(((worldX - this.minX) / xRange) * GRID_CELLS))
    );
    const row = Math.min(
      GRID_CELLS - 1,
      Math.max(0, Math.floor(((worldY - this.minY) / yRange) * GRID_CELLS))
    );

    let bestIdx = -1;
    let bestDist = maxWorldDist * maxWorldDist;
    const { points } = this;
    for (let dr = -1; dr <= 1; dr++) {
      for (let dc = -1; dc <= 1; dc++) {
        const r = row + dr;
        const c = col + dc;
        if (r < 0 || c < 0 || r >= GRID_CELLS || c >= GRID_CELLS) {
          continue;
        }
        const cell = grid[r * GRID_CELLS + c];
        if (!cell) {
          continue;
        }
        for (const idx of cell) {
          const p = points[idx];
          const dx = p[X] - worldX;
          const dy = p[Y] - worldY;
          const d2 = dx * dx + dy * dy;
          if (d2 < bestDist) {
            bestDist = d2;
            bestIdx = idx;
          }
        }
      }
    }
    return bestIdx;
  }

  @action
  onPointerDown(e) {
    this.dragging = true;
    this.dragMoved = false;
    this.lastPointerX = e.offsetX;
    this.lastPointerY = e.offsetY;
    this.canvas.setPointerCapture(e.pointerId);
  }

  @action
  onPointerMove(e) {
    if (this.dragging) {
      const dx = e.offsetX - this.lastPointerX;
      const dy = e.offsetY - this.lastPointerY;
      if (dx !== 0 || dy !== 0) {
        this.offsetX += dx;
        this.offsetY += dy;
        this.lastPointerX = e.offsetX;
        this.lastPointerY = e.offsetY;
        this.dragMoved = true;
        this.draw();
      }
      return;
    }

    const world = this.screenToWorld(e.offsetX, e.offsetY);
    const maxWorldDist = HOVER_RADIUS_PX / this.scale;
    const idx = this.findNearest(world.x, world.y, maxWorldDist);
    const prevClusterIdx = this.hoveredClusterIdx;
    if (idx >= 0) {
      const p = this.points[idx];
      this.hoveredTitle = p[TITLE];
      this.hoveredClusterIdx = p[CLUSTER_IDX];
      this.hoverX = e.offsetX;
      this.hoverY = e.offsetY;
    } else {
      this.hoveredTitle = null;
      this.hoveredClusterIdx = null;
    }
    // Only redraw the canvas when the cluster under the cursor changes —
    // pointer moves within a single cluster happen constantly and don't
    // affect what's drawn.
    if (this.isClusterView && prevClusterIdx !== this.hoveredClusterIdx) {
      this.draw();
    }
  }

  @action
  onPointerUp(e) {
    if (this.dragging) {
      this.canvas.releasePointerCapture(e.pointerId);
    }
    const wasDrag = this.dragMoved;
    this.dragging = false;
    this.dragMoved = false;

    if (!wasDrag) {
      const world = this.screenToWorld(e.offsetX, e.offsetY);
      const maxWorldDist = HOVER_RADIUS_PX / this.scale;
      const idx = this.findNearest(world.x, world.y, maxWorldDist);
      if (idx >= 0) {
        const p = this.points[idx];
        this.router.transitionTo(`/t/${p[SLUG]}/${p[TOPIC_ID]}`);
      }
    }
  }

  @action
  onPointerLeave() {
    this.hoveredTitle = null;
    this.hoveredClusterIdx = null;
    this.dragging = false;
    if (this.isClusterView) {
      this.draw();
    }
  }

  @action
  onWheel(e) {
    e.preventDefault();
    const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    const world = this.screenToWorld(e.offsetX, e.offsetY);
    this.scale *= factor;
    this.offsetX = e.offsetX - world.x * this.scale;
    this.offsetY = e.offsetY - world.y * this.scale;
    this.draw();
  }

  swatchStyle(color) {
    return trustHTML(`background:#${color || "888"}`);
  }

  tooltipStyle(x, y) {
    return trustHTML(`left:${x + 12}px;top:${y + 12}px`);
  }

  @action
  updateQuery(e) {
    this.query = e.target.value;
  }

  @action
  resetView() {
    this.resizeCanvas();
    this.draw();
  }

  @action
  showCategoryView() {
    this.viewMode = "category";
    this.draw();
  }

  @action
  showClusterView() {
    this.viewMode = "clusters";
    this.draw();
  }

  <template>
    <div class="embedding-map">
      <div class="embedding-map__header">
        <h1>{{i18n "embedding_map.title"}}</h1>
        <p class="embedding-map__description">
          {{i18n "embedding_map.description"}}
        </p>
        <div class="embedding-map__controls">
          <div class="embedding-map__tabs">
            <button
              type="button"
              class="embedding-map__tab
                {{if this.isCategoryView 'embedding-map__tab--active'}}"
              {{on "click" this.showCategoryView}}
            >
              {{i18n "embedding_map.tab_category"}}
            </button>
            <button
              type="button"
              class="embedding-map__tab
                {{if this.isClusterView 'embedding-map__tab--active'}}"
              {{on "click" this.showClusterView}}
            >
              {{i18n "embedding_map.tab_clusters"}}
            </button>
          </div>
          <input
            type="search"
            class="embedding-map__search"
            placeholder={{i18n "embedding_map.search_placeholder"}}
            value={{this.query}}
            {{on "input" this.updateQuery}}
          />
          <button
            type="button"
            class="btn btn-default"
            {{on "click" this.resetView}}
          >
            {{i18n "embedding_map.reset_view"}}
          </button>
          <span class="embedding-map__count">
            {{i18n "embedding_map.topics_shown" count=this.visiblePointCount}}
          </span>
        </div>
      </div>

      <div class="embedding-map__canvas-wrapper">
        {{! template-lint-disable no-pointer-down-event-binding }}
        <canvas
          class="embedding-map__canvas"
          {{didInsert this.setup}}
          {{willDestroy this.teardown}}
          {{on "pointerdown" this.onPointerDown}}
          {{on "pointermove" this.onPointerMove}}
          {{on "pointerup" this.onPointerUp}}
          {{on "pointerleave" this.onPointerLeave}}
          {{on "wheel" this.onWheel passive=false}}
        ></canvas>

        {{#if this.hoveredTitle}}
          <div
            class="embedding-map__tooltip"
            style={{this.tooltipStyle this.hoverX this.hoverY}}
          >
            {{this.hoveredTitle}}
          </div>
        {{/if}}
      </div>

      <aside class="embedding-map__legend">
        <h3>
          {{if
            this.isClusterView
            (i18n "embedding_map.legend_clusters")
            (i18n "embedding_map.legend_categories")
          }}
        </h3>
        <ul>
          {{#each this.legendEntries as |entry|}}
            <li>
              <span
                class="embedding-map__swatch"
                style={{this.swatchStyle entry.color}}
              ></span>
              <span class="embedding-map__legend-name">{{entry.name}}</span>
              {{#if entry.size}}
                <span class="embedding-map__legend-size">{{entry.size}}</span>
              {{/if}}
            </li>
          {{/each}}
        </ul>
      </aside>
    </div>
  </template>
}
