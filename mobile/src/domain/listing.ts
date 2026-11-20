import { parsePrice } from './money';

export type ItemCondition = 'new' | 'used_like_new' | 'used_good' | 'used_fair';

export const CONDITIONS: { value: ItemCondition; label: string }[] = [
  { value: 'new', label: 'New' },
  { value: 'used_like_new', label: 'Used, like new' },
  { value: 'used_good', label: 'Used, good' },
  { value: 'used_fair', label: 'Used, fair' },
];

export function conditionLabel(value: ItemCondition): string {
  return CONDITIONS.find((c) => c.value === value)?.label ?? value;
}

export const MAX_PHOTOS = 8;

export type ListingForm = {
  title: string;
  price: string;
  description: string;
  categoryId: number | null;
  locationId: number | null;
  condition: ItemCondition | null;
  warrantyInfo: string;
  returnPolicy: string;
  photoCount: number;
};

export type ListingErrors = Partial<Record<keyof ListingForm, string>>;

// Mirrors the checks in the database. The database is the one that enforces them;
// this only saves a round trip and gives friendlier wording.
export function validateListing(form: ListingForm): ListingErrors {
  const errors: ListingErrors = {};
  const title = form.title.trim();

  if (title.length < 3) errors.title = 'Give the item a short title, at least 3 letters.';
  else if (title.length > 120) errors.title = 'Keep the title under 120 characters.';

  if (parsePrice(form.price) === null) errors.price = 'Enter the price in kwacha, for example 2500.';
  if (form.categoryId === null) errors.categoryId = 'Choose a category.';
  if (form.locationId === null) errors.locationId = 'Choose where the item is.';
  if (form.condition === null) errors.condition = 'Say what condition it is in.';
  if (form.description.length > 4000) errors.description = 'The description is too long.';
  if (form.warrantyInfo.length > 500) errors.warrantyInfo = 'Keep warranty details under 500 characters.';
  if (form.returnPolicy.length > 500) errors.returnPolicy = 'Keep return details under 500 characters.';

  if (form.photoCount < 1) errors.photoCount = 'Add at least one photo of the item.';
  else if (form.photoCount > MAX_PHOTOS) errors.photoCount = `You can add up to ${MAX_PHOTOS} photos.`;

  return errors;
}
