import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { service } from "@ember/service";
import { trustHTML } from "@ember/template";
import loadScript from "discourse/lib/load-script";
import { i18n } from "discourse-i18n";

const SCATTERPLOT_SCRIPT =
  "/plugins/discourse-embedding-map/javascripts/regl-scatterplot.bundle.js";

// Index format (matches controller serialization):
//   [topic_id, x, y, category_id, created_at_epoch, slug, title]
const TOPIC_ID = 0;
const X = 1;
const Y = 2;
const CATEGORY_ID = 3;
const SLUG = 5;
const TITLE = 6;

export default class EmbeddingMapViewer extends Component {
  @service router;

  @tracked hoveredTitle = null;
  @tracked query = "";

  scatterplot = null;
  canvas = null;
  resizeObserver = null;
  categoryIndexMap = new Map();

  get points() {
    return this.args.data?.points ?? [];
  }

  get categories() {
    return this.args.data?.categories ?? [];
  }

  get visiblePointCount() {
    return this.points.length;
  }

  @action
  async setup(element) {
    this.canvas = element;
    await this.mountScatterplot();
  }

  @action
  teardown() {
    this.resizeObserver?.disconnect();
    this.scatterplot?.destroy();
    this.scatterplot = null;
  }

  async mountScatterplot() {
    const { points, categories } = this;
    if (!points.length) {
      return;
    }

    await loadScript(SCATTERPLOT_SCRIPT);
    const createScatterplot = window.ReglScatterplot.default;

    const categoryColors = categories.map((c) =>
      c.color ? `#${c.color}` : "#888888"
    );
    categories.forEach((c, i) => this.categoryIndexMap.set(c.id, i));

    const { width, height } = this.canvas.getBoundingClientRect();

    this.scatterplot = createScatterplot({
      canvas: this.canvas,
      width,
      height,
      pointSize: 3,
      opacity: 0.7,
      lassoOnLongPress: true,
    });

    // regl-scatterplot expects coordinates in [-1, 1]. UMAP output is
    // unbounded, so center on the midpoint and scale by the longer axis.
    const { xs, ys } = this.bounds(points);
    const xMid = (xs.min + xs.max) / 2;
    const yMid = (ys.min + ys.max) / 2;
    const scale = 2 / Math.max(xs.max - xs.min, ys.max - ys.min, 1e-6);

    const data = points.map((p) => [
      (p[X] - xMid) * scale,
      (p[Y] - yMid) * scale,
      this.categoryIndexMap.get(p[CATEGORY_ID]) ?? 0,
    ]);

    this.scatterplot.set({ colorBy: "valueA", pointColor: categoryColors });
    await this.scatterplot.draw(data);

    this.scatterplot.subscribe("pointOver", (pointIdx) => {
      const p = points[pointIdx];
      this.hoveredTitle = p?.[TITLE] ?? null;
    });
    this.scatterplot.subscribe("pointOut", () => {
      this.hoveredTitle = null;
    });
    this.scatterplot.subscribe("pointClick", (pointIdx) => {
      const p = points[pointIdx];
      if (p) {
        this.router.transitionTo(`/t/${p[SLUG]}/${p[TOPIC_ID]}`);
      }
    });

    this.resizeObserver = new ResizeObserver(() => {
      const r = this.canvas.getBoundingClientRect();
      this.scatterplot?.set({ width: r.width, height: r.height });
    });
    this.resizeObserver.observe(this.canvas.parentElement);
  }

  bounds(points) {
    let xMin = Infinity;
    let xMax = -Infinity;
    let yMin = Infinity;
    let yMax = -Infinity;
    for (const p of points) {
      if (p[X] < xMin) {
        xMin = p[X];
      }
      if (p[X] > xMax) {
        xMax = p[X];
      }
      if (p[Y] < yMin) {
        yMin = p[Y];
      }
      if (p[Y] > yMax) {
        yMax = p[Y];
      }
    }
    return { xs: { min: xMin, max: xMax }, ys: { min: yMin, max: yMax } };
  }

  swatchStyle(color) {
    return trustHTML(`background:#${color || "888"}`);
  }

  @action
  updateQuery(e) {
    this.query = e.target.value;
  }

  @action
  resetView() {
    this.scatterplot?.reset();
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
        <canvas
          class="embedding-map__canvas"
          {{didInsert this.setup}}
          {{willDestroy this.teardown}}
        ></canvas>

        {{#if this.hoveredTitle}}
          <div class="embedding-map__tooltip">{{this.hoveredTitle}}</div>
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
