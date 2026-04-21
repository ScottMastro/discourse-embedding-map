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
const CREATED_AT = 4;
const SLUG = 5;
const TITLE = 6;
const CLUSTER_IDX = 7;

const POINT_SIZE = 3;
const HOVER_RADIUS_PX = 6;
const GRID_CELLS = 128;

// Playback speed: 3 months of forum time per 1 second of real time.
const PLAYBACK_SECONDS_PER_SECOND = 60 * 60 * 24 * 30 * 3;
// Points created within this window of the playhead pop with a ring.
const POP_WINDOW_SECONDS = 60 * 60 * 24 * 30 * 3;
// During playback, points older than this gradually fade to gray.
const FADE_WINDOW_SECONDS = 60 * 60 * 24 * 365;
const FADE_COLOR = [170, 170, 170];

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

  // Playback state. playhead is an epoch timestamp; when null the full
  // dataset is shown (playback disabled). minTime/maxTime are the earliest
  // and latest created_at in the visible point set.
  @tracked playing = false;
  @tracked playhead = null;
  minTime = 0;
  maxTime = 0;
  rafId = null;
  lastFrameTs = 0;

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
  initialScale = 1;

  dragging = false;
  lastPointerX = 0;
  lastPointerY = 0;
  dragMoved = false;

  spatialGrid = null;

  // Cache parsed "#rrggbb" → [r,g,b] so we don't re-parse per point.
  _rgbCache = new Map();

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

  // Zoom-aware minimum cluster size for drawing a label. At the fit-to-screen
  // zoom we want only the top ~15 clusters labeled; as the user zooms in, the
  // threshold drops quadratically with the ratio of scales, so 2× zoom shows
  // ~4× more labels. Collision avoidance in drawClusterLabels prunes further.
  minLabelSize() {
    const ratio = (this.initialScale || 1) / (this.scale || 1);
    const base = 100;
    return Math.max(10, Math.round(base * ratio * ratio));
  }

  get labeledClusters() {
    const threshold = this.minLabelSize();
    return this.clusters.filter((c) => c.size >= threshold);
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
    this.fitTimeBounds();
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
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
  }

  fitTimeBounds() {
    const { points } = this;
    if (!points.length) {
      return;
    }
    let tMin = Infinity;
    let tMax = -Infinity;
    for (const p of points) {
      const t = p[CREATED_AT];
      if (t < tMin) {
        tMin = t;
      }
      if (t > tMax) {
        tMax = t;
      }
    }
    this.minTime = tMin;
    this.maxTime = tMax;
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
    this.initialScale = this.scale;
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

  hexToRgb(hex) {
    let rgb = this._rgbCache.get(hex);
    if (rgb) {
      return rgb;
    }
    const h = hex.startsWith("#") ? hex.slice(1) : hex;
    rgb = [
      parseInt(h.slice(0, 2), 16),
      parseInt(h.slice(2, 4), 16),
      parseInt(h.slice(4, 6), 16),
    ];
    this._rgbCache.set(hex, rgb);
    return rgb;
  }

  // Mix rgb color toward FADE_COLOR by fraction t ∈ [0, 1] and return #rrggbb.
  mixToFade(hex, t) {
    const [r, g, b] = this.hexToRgb(hex);
    const mix = (a, b2) => Math.round(a + (b2 - a) * t);
    const r2 = mix(r, FADE_COLOR[0]);
    const g2 = mix(g, FADE_COLOR[1]);
    const b2 = mix(b, FADE_COLOR[2]);
    return `#${r2.toString(16).padStart(2, "0")}${g2.toString(16).padStart(2, "0")}${b2.toString(16).padStart(2, "0")}`;
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

    const { points, playhead } = this;
    const size = POINT_SIZE;
    const half = size / 2;
    const popBoundary =
      playhead !== null ? playhead - POP_WINDOW_SECONDS : null;
    const FADE_TIERS = 8;

    // Bucket by color to minimize fillStyle changes. When the playhead is set,
    // skip any point created after it, and quantize age into fade tiers so
    // older points drift to gray without producing thousands of unique
    // fillStyles.
    const buckets = new Map();
    const popping = [];
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      if (playhead !== null && p[CREATED_AT] > playhead) {
        continue;
      }
      const baseColor = this.colorForPoint(p);
      let color = baseColor;
      if (playhead !== null) {
        const age = playhead - p[CREATED_AT];
        const rawT = Math.min(1, Math.max(0, age / FADE_WINDOW_SECONDS));
        const tier = Math.round(rawT * FADE_TIERS) / FADE_TIERS;
        if (tier > 0) {
          color = this.mixToFade(baseColor, tier);
        }
      }
      let list = buckets.get(color);
      if (!list) {
        list = [];
        buckets.set(color, list);
      }
      list.push(p);
      if (popBoundary !== null && p[CREATED_AT] >= popBoundary) {
        popping.push([p, baseColor]);
      }
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

    // Draw a fading ring around recently-born points so the "play" effect
    // feels alive — a point that appeared in the last 3 months pops, fading
    // linearly out to an ordinary dot.
    if (popping.length > 0 && playhead !== null) {
      const window = POP_WINDOW_SECONDS || 1;
      for (const [p, color] of popping) {
        const age = Math.max(0, playhead - p[CREATED_AT]);
        const strength = Math.max(0, 1 - age / window);
        if (strength <= 0.01) {
          continue;
        }
        const sx = p[X] * this.scale + this.offsetX;
        const sy = p[Y] * this.scale + this.offsetY;
        const ringR = 2 + 8 * strength;
        ctx.globalAlpha = strength * 0.6;
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.arc(sx, sy, ringR, 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      ctx.lineWidth = 1;
    }

    if (this.isClusterView) {
      this.drawClusterLabels();
    }
  }

  drawClusterLabels() {
    const ctx = this.ctx;
    const hoveredIdx = this.hoveredClusterIdx;
    const hoveredCluster =
      hoveredIdx !== null && hoveredIdx !== undefined
        ? this.clusters.find((c) => c.idx === hoveredIdx)
        : null;

    // Largest clusters get placement priority — we add them first and skip any
    // later label whose box would overlap one already placed. The hovered
    // cluster, if any, is reserved and always placed last on top.
    const candidates = [...this.labeledClusters].sort(
      (a, b) => b.size - a.size
    );

    const placed = [];
    const boxes = [];

    const intersects = (a, b) =>
      a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;

    // Pre-measure to decide which labels survive collision pruning.
    ctx.font = "12px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif";
    for (const c of candidates) {
      if (c === hoveredCluster) {
        continue;
      }
      const text = c.label || c.keywords?.slice(0, 2).join(", ");
      if (!text) {
        continue;
      }
      const sx = c.cx * this.scale + this.offsetX;
      const sy = c.cy * this.scale + this.offsetY;
      const m = ctx.measureText(text);
      const w = m.width + 12;
      const h = 18;
      const box = { x: sx - w / 2, y: sy - h / 2, w, h };
      if (boxes.some((b) => intersects(b, box))) {
        continue;
      }
      boxes.push(box);
      placed.push(c);
    }

    if (hoveredCluster) {
      placed.push(hoveredCluster);
    }

    for (const c of placed) {
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

  get playheadLabel() {
    if (this.playhead === null) {
      return "";
    }
    return new Date(this.playhead * 1000).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
    });
  }

  get bigDateLabel() {
    if (this.playhead === null) {
      return null;
    }
    return new Date(this.playhead * 1000).toLocaleDateString(undefined, {
      year: "numeric",
      month: "long",
    });
  }

  get timelineMin() {
    return this.minTime;
  }

  get timelineMax() {
    return this.maxTime;
  }

  get timelineValue() {
    return this.playhead ?? this.maxTime;
  }

  @action
  togglePlay() {
    if (this.playing) {
      this.pause();
    } else {
      this.play();
    }
  }

  play() {
    if (this.maxTime <= this.minTime) {
      return;
    }
    // Rewind if we're already at or past the end.
    if (this.playhead === null || this.playhead >= this.maxTime) {
      this.playhead = this.minTime;
    }
    this.playing = true;
    this.lastFrameTs = performance.now();
    const tick = (now) => {
      if (!this.playing) {
        return;
      }
      const dtSeconds = (now - this.lastFrameTs) / 1000;
      this.lastFrameTs = now;
      const next =
        (this.playhead ?? this.minTime) +
        dtSeconds * PLAYBACK_SECONDS_PER_SECOND;
      if (next >= this.maxTime) {
        this.playhead = this.maxTime;
        this.playing = false;
        this.draw();
        return;
      }
      this.playhead = next;
      this.draw();
      this.rafId = requestAnimationFrame(tick);
    };
    this.rafId = requestAnimationFrame(tick);
  }

  pause() {
    this.playing = false;
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
  }

  @action
  onTimelineInput(e) {
    this.pause();
    const v = parseInt(e.target.value, 10);
    // Treat the extreme-right position as "off" so the full dataset is shown
    // and the user isn't stuck filtering out topics created in the last hour.
    this.playhead = v >= this.maxTime ? null : v;
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

        <div class="embedding-map__timeline">
          <button
            type="button"
            class="btn btn-default embedding-map__play"
            {{on "click" this.togglePlay}}
          >
            {{if
              this.playing
              (i18n "embedding_map.pause")
              (i18n "embedding_map.play")
            }}
          </button>
          <input
            type="range"
            class="embedding-map__slider"
            min={{this.timelineMin}}
            max={{this.timelineMax}}
            value={{this.timelineValue}}
            {{on "input" this.onTimelineInput}}
          />
          <span class="embedding-map__playhead-label">
            {{this.playheadLabel}}
          </span>
        </div>
      </div>

      <div class="embedding-map__canvas-wrapper">
        {{#if this.bigDateLabel}}
          <div class="embedding-map__big-date">{{this.bigDateLabel}}</div>
        {{/if}}
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
