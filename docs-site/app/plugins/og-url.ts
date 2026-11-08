import { joinURL } from "ufo";

export default defineNuxtPlugin(() => {
  const site = useSiteConfig();
  const route = useRoute();
  const baseURL = useRuntimeConfig().app.baseURL;

  useHead({
    meta: [
      {
        property: "og:url",
        content: computed(() =>
          site.url ? joinURL(site.url, baseURL, route.path) : undefined,
        ),
        tagPriority: "high",
      },
    ],
  });
});
