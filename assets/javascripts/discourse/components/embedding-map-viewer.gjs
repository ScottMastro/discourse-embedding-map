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
//   [topic_id, x, y, category_id, created_at_epoch, slug, title]
const TOPIC_ID = 0;
const X = 1;
const Y = 2;
const CATEGORY_ID = 3;
const SLUG = 5;
const TITLE = 6;

const POINT_SIZE = 3;
const HOVER_RADIUS_PX = 6;
const GRID_CELLS = 128;

export default class EmbeddingMapViewer extends Component {
  @service router;

  @tracked hoveredTitle = null;
  @tracked hoverX = 0;
  @tracked hoverY = 0;
  @tracked query = "";

  canvas = null;
  ctx = null;
  resizeObserver = null;

  // World-space bounds of the raw UMAP output.
  minX = 0;
  maxX = 0;
  minY = 0;
  maxY = 0;

  // View transform: world → screen. scale is pixels per world unit.
  scale = 1;
  offsetX = 0;
  offsetY = 0;

  // Interaction state.
  dragging = false;
  lastPointerX = 0;
  lastPointerY = 0;
  dragMoved = false;

  // Spatial grid for hover hit-testing. Indexed by `row * GRID_CELLS + col`,
  // each cell holds an array of point indices whose world position falls in
  // that cell. Rebuilt once after mount; pan/zoom only changes the transform.
  spatialGrid = null;

  get points() {
    return this.args.data?.points ?? [];
  }

  get categories() {
    return this.args.data?.categories ?? [];
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

    // Reset the view to fit all points with a 5% margin.
    const pad = 0.05;
    const xRange = (this.maxX - this.minX) * (1 + 2 * pad) || 1;
    const yRange = (this.maxY - this.minY) * (1 + 2 * pad) || 1;
    this.scale = Math.min(cssW / xRange, cssH / yRange);
    const worldMidX = (this.minX + this.maxX) / 2;
    const worldMidY = (this.minY + this.maxY) / 2;
    this.offsetX = cssW / 2 - worldMidX * this.scale;
    this.offsetY = cssH / 2 - worldMidY * this.scale;
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
    const colorMap = this.categoryColorMap;
    const size = POINT_SIZE;
    const half = size / 2;

    // Group by color to minimize fillStyle changes (expensive on canvas 2D).
    const buckets = new Map();
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const color = colorMap.get(p[CATEGORY_ID]) ?? "#888888";
      let list = buckets.get(color);
      if (!list) {
        list = [];
        buckets.set(color, list);
      }
      list.push(p);
    }

    ctx.globalAlpha = 0.85;
    for (const [color, list] of buckets) {
      ctx.fillStyle = color;
      for (const p of list) {
        const sx = p[X] * this.scale + this.offsetX;
        const sy = p[Y] * this.scale + this.offsetY;
        ctx.fillRect(sx - half, sy - half, size, size);
      }
    }
    ctx.globalAlpha = 1;
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
    if (idx >= 0) {
      const p = this.points[idx];
      this.hoveredTitle = p[TITLE];
      this.hoverX = e.offsetX;
      this.hoverY = e.offsetY;
    } else {
      this.hoveredTitle = null;
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
    this.dragging = false;
  }

  @action
  onWheel(e) {
    e.preventDefault();
    const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    // Zoom around the cursor: keep the world point under the pointer fixed.
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

  <template>
    <div class="embedding-map">
      <div class="embedding-map__header">
        <h1>{{i18n "embedding_map.title"}}</h1>
        <p class="embedding-map__description">
          {{i18n "embedding_map.description"}}
        </p>
        <div class="embedding-map__controls">
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
        <h3>{{i18n "embedding_map.legend_title"}}</h3>
        <ul>
          {{#each this.categories as |cat|}}
            <li>
              <span
                class="embedding-map__swatch"
                style={{this.swatchStyle cat.color}}
              ></span>
              {{cat.name}}
            </li>
          {{/each}}
        </ul>
      </aside>
    </div>
  </template>
}
