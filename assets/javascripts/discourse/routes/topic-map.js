import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

export default class TopicMapRoute extends DiscourseRoute {
  titleToken() {
    return i18n("embedding_map.title");
  }

  async model() {
    try {
      return await ajax("/topic-map.json");
    } catch (e) {
      popupAjaxError(e);
      throw e;
    }
  }
}
