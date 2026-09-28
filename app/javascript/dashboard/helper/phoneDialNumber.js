import {
  findPhoneNumbersInText,
  parsePhoneNumberFromString,
} from 'libphonenumber-js';

// Numbers without a country code are local to the clinic (8 7xx..., 7xx...).
export const DEFAULT_DIAL_COUNTRY = 'KZ';

// Turns whatever an operator typed or pasted — "8 (701) 123-45-67",
// "+7 701 123 45 67", "77011234567", a copied contact line with a name or a
// trailing newline — into the E.164 number to dial, or '' when the text holds
// no complete valid number.
export const normalizeDialNumber = (
  text,
  defaultCountry = DEFAULT_DIAL_COUNTRY
) => {
  const value = String(text ?? '').trim();
  if (!value) return '';

  const parsed = parsePhoneNumberFromString(value, defaultCountry);
  if (parsed?.isValid()) return parsed.number;

  const match = findPhoneNumbersInText(value, defaultCountry).find(
    ({ number }) => number?.isValid()
  );
  return match ? match.number.number : '';
};
