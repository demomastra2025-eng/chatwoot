// A phone number typed into a search box in any format: 87072817060, +77072817060, 7 707 281 70 60,
// +7 (707) 281-70-60, 8-707-281-70-60 are the same number. The rules are the same as on the server
// (app/services/search/phone_query.rb), so that the list of loaded conversations and the server-side search agree:
//   - 10 digits or more: the last 10 digits are compared (8 / +7 / 7 / 0 and other country codes do not matter);
//   - 4 to 15 digits: the digits are looked for inside the stored digits, also without a leading 7, 8 or 0, so a
//     number is found while it is being typed and also by a fragment from the middle;
//   - 1-3 digits are not a phone search.

const MIN_DIGITS = 4;
const MAX_DIGITS = 15;
const NATIONAL_DIGITS = 10;
const PREFIXES = ['7', '8', '0'];
// Direction marks, zero-width characters and other invisible format characters that come with copied text.
const INVISIBLE_CHARS =
  /[\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF]/g;
// Digits with the usual separators (spaces of any kind, dots, dashes of every kind, brackets, one leading plus).
const PHONE_INPUT = /^\+?[\s\d().\-\u2010-\u2015\u2212]+$/;

// Full-width ASCII (＋７ ７０７) becomes plain ASCII, exotic spaces become plain ones, invisible marks disappear. NFKC is
// not used on purpose: it rewrites "№", "…", "²" and "™" into "No", "...", "2" and "TM", which stay as typed in the
// stored text (the same rule as app/services/search/query_text.rb).
const FULL_WIDTH_ASCII = /[\uFF01-\uFF5E]/g;
const FULL_WIDTH_OFFSET = 0xfee0;

export const cleanSearchText = value =>
  String(value ?? '')
    .normalize('NFC')
    .replace(FULL_WIDTH_ASCII, char =>
      String.fromCharCode(char.charCodeAt(0) - FULL_WIDTH_OFFSET)
    )
    .replace(INVISIBLE_CHARS, '')
    .replace(/\s+/g, ' ')
    .trim();

const digitsOf = value => String(value ?? '').replace(/\D/g, '');

// The digits of the typed text, or null when it is not a phone number.
export const parsePhoneQuery = text => {
  const cleaned = cleanSearchText(text);
  if (!PHONE_INPUT.test(cleaned)) return null;

  const digits = digitsOf(cleaned);
  if (digits.length < MIN_DIGITS || digits.length > MAX_DIGITS) return null;

  return digits;
};

export const phoneFragments = digits => {
  const fragments = [digits];
  if (PREFIXES.includes(digits[0]) && digits.length - 1 >= MIN_DIGITS) {
    fragments.push(digits.slice(1));
  }
  return fragments;
};

export const phoneMatchesQuery = (phone, text) => {
  const queryDigits = parsePhoneQuery(text);
  const storedDigits = digitsOf(phone);
  if (!queryDigits || !storedDigits) return false;

  if (
    queryDigits.length >= NATIONAL_DIGITS &&
    storedDigits.length >= NATIONAL_DIGITS &&
    storedDigits.slice(-NATIONAL_DIGITS) === queryDigits.slice(-NATIONAL_DIGITS)
  ) {
    return true;
  }

  return phoneFragments(queryDigits).some(fragment =>
    storedDigits.includes(fragment)
  );
};
