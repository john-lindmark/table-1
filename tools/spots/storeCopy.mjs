/**
 * Store listings composed from the feature spots (marketing/bundle/spots/spots.json): the same copy the landing page
 * and the apps' sign-in carousel show. copy.mjs writes them to marketing/store/; the web's spots.test.ts keeps them
 * within Apple's and Google's limits.
 */
export const LIMITS = {
  appStore: { name: 30, subtitle: 30, promotionalText: 170, description: 4000, keywords: 100 },
  play: { title: 30, shortDescription: 80, fullDescription: 4000 },
};

/** One paragraph per store spot: the title in capitals, then its body. */
function spotParagraphs(file) {
  return file.spots.filter((s) => s.store).map((s) => `${s.title.toUpperCase()}\n${s.body}`);
}

const PLATFORMS = "Table 1 is free, with no ads or purchases, and the same account works on iPhone, Android and the web at table-1.site.";

export function appStoreListing(file) {
  const p = file.product;
  return {
    name: p.name,
    subtitle: file.store.subtitle,
    promotionalText: file.store.promotional_text,
    description: [`${p.tagline}.`, p.line, ...spotParagraphs(file), PLATFORMS, p.fan_content].join("\n\n"),
    keywords: file.store.keywords,
  };
}

export function playListing(file) {
  const p = file.product;
  return {
    title: p.name,
    shortDescription: file.store.short_description,
    fullDescription: [`${p.tagline}.`, p.line, ...spotParagraphs(file), PLATFORMS, p.fan_content].join("\n\n"),
  };
}

/** The screenshots in listing order: the store spots, numbered. */
export function screenshotOrder(file) {
  return file.spots.filter((s) => s.store).map((s, i) => ({ n: i + 1, key: s.key, headline: s.headline }));
}
