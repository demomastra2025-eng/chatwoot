export const normalizeComboboxSearchText = value =>
  String(value || '')
    .normalize('NFKC')
    .toLocaleLowerCase()
    .replace(/\s+/gu, ' ')
    .trim();
