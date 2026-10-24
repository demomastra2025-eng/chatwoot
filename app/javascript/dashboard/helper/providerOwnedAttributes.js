import { ExceptionWithMessage } from 'shared/helpers/CustomErrors';

// MedElement owns part of the contact attributes: it writes them on every sync
// and the server refuses a change made from the dashboard. This is the same
// rule as Integrations::Medelement::ProviderOwnedAttributesGuard, so the panel
// can show such a field as read-only instead of offering an edit that fails.
const PROVIDER_PREFIX = 'medelement_';
const PATIENT_CODE_KEY = 'medelement_patient_code';

// The staff fills these in even for a patient card.
const USER_EDITABLE_KEYS = ['birth_date', 'gender', 'iin'];

// Taken from MedElement only once the card is a patient card (has a code).
const PROVIDER_DERIVED_KEYS = [
  'address',
  'phone_conflict_comment',
  'secondary_phones',
];

const isPresent = value =>
  value !== null && value !== undefined && String(value).trim() !== '';

export const isProviderOwnedAttribute = (key, customAttributes = {}) => {
  const attributeKey = String(key || '');
  if (USER_EDITABLE_KEYS.includes(attributeKey)) return false;
  if (attributeKey.startsWith(PROVIDER_PREFIX)) return true;

  return (
    PROVIDER_DERIVED_KEYS.includes(attributeKey) &&
    isPresent(customAttributes?.[PATIENT_CODE_KEY])
  );
};

// The text the server answers with when it refuses a request, if any. The
// contacts store hands the failure over as an exception that keeps this text.
export const serverErrorMessage = error =>
  error?.response?.data?.error ||
  error?.response?.data?.message ||
  error?.contactErrorDetail ||
  (error instanceof ExceptionWithMessage && error.data) ||
  '';
