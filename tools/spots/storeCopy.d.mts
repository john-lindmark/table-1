export const LIMITS: {
  appStore: { name: number; subtitle: number; promotionalText: number; description: number; keywords: number };
  play: { title: number; shortDescription: number; fullDescription: number };
};
export function appStoreListing(file: unknown): { name: string; subtitle: string; promotionalText: string; description: string; keywords: string };
export function playListing(file: unknown): { title: string; shortDescription: string; fullDescription: string };
export function screenshotOrder(file: unknown): { n: number; key: string; headline: string }[];
