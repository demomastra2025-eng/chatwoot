export const normalizePatientIin = value =>
  String(value || '').replace(/\D/g, '');

// Reuses the two-pass checksum from Scheduling::IinValidator and the sidebar.
export const isValidPatientIin = value => {
  const iin = normalizePatientIin(value);
  if (!/^\d{12}$/.test(iin)) return false;

  const digits = [...iin].map(Number);
  const checksum = weights =>
    weights.reduce((sum, weight, index) => sum + weight * digits[index], 0) %
    11;
  const first = checksum([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  const result =
    first === 10 ? checksum([3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]) : first;
  return (result === 10 ? 0 : result) === digits[11];
};

// The existing calendar patient form's date/gender decoder. Checksum validation
// stays separate so extracting it does not change the calendar editing flow.
export const parseIinMetadata = iinValue => {
  const normalizedIin = normalizePatientIin(iinValue);
  if (!normalizedIin) return { reason: '', valid: true };
  if (normalizedIin.length !== 12) return { reason: 'length', valid: false };

  const centuryCode = Number(normalizedIin[6]);
  const centuryMap = {
    1: { century: 1800, gender: 'male' },
    2: { century: 1800, gender: 'female' },
    3: { century: 1900, gender: 'male' },
    4: { century: 1900, gender: 'female' },
    5: { century: 2000, gender: 'male' },
    6: { century: 2000, gender: 'female' },
  };
  if (centuryCode === 0) return { reason: 'foreign', valid: false };
  const metadata = centuryMap[centuryCode];
  if (!metadata) return { reason: 'format', valid: false };

  const year = metadata.century + Number(normalizedIin.slice(0, 2));
  const month = Number(normalizedIin.slice(2, 4));
  const day = Number(normalizedIin.slice(4, 6));
  const parsedDate = new Date(year, month - 1, day);
  if (
    Number.isNaN(parsedDate.getTime()) ||
    parsedDate.getFullYear() !== year ||
    parsedDate.getMonth() !== month - 1 ||
    parsedDate.getDate() !== day
  ) {
    return { reason: 'date', valid: false };
  }
  return {
    birthDate: `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`,
    gender: metadata.gender,
    reason: '',
    valid: true,
  };
};
