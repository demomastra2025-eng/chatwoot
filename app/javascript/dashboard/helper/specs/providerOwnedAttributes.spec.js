import { ExceptionWithMessage } from 'shared/helpers/CustomErrors';
import {
  isProviderOwnedAttribute,
  serverErrorMessage,
} from '../providerOwnedAttributes';

describe('isProviderOwnedAttribute', () => {
  it('owns every medelement_ key, with or without a value', () => {
    expect(isProviderOwnedAttribute('medelement_patient_code', {})).toBe(true);
    expect(isProviderOwnedAttribute('medelement_last_synced_at', {})).toBe(
      true
    );
    expect(isProviderOwnedAttribute('medelement_first_name')).toBe(true);
  });

  it('leaves the fields the staff fills in editable', () => {
    const patient = { medelement_patient_code: 'P-1' };
    ['birth_date', 'gender', 'iin'].forEach(key => {
      expect(isProviderOwnedAttribute(key, patient)).toBe(false);
    });
    expect(isProviderOwnedAttribute('clinical_note', patient)).toBe(false);
  });

  it('owns the derived fields only on a patient card', () => {
    ['address', 'secondary_phones', 'phone_conflict_comment'].forEach(key => {
      expect(isProviderOwnedAttribute(key, {})).toBe(false);
      expect(
        isProviderOwnedAttribute(key, { medelement_patient_code: '  ' })
      ).toBe(false);
      expect(
        isProviderOwnedAttribute(key, { medelement_patient_code: 'P-1' })
      ).toBe(true);
    });
  });

  it('copes with missing attributes', () => {
    expect(isProviderOwnedAttribute('address', null)).toBe(false);
    expect(isProviderOwnedAttribute(undefined, undefined)).toBe(false);
  });
});

describe('serverErrorMessage', () => {
  it('prefers the text of the server response', () => {
    expect(
      serverErrorMessage({
        response: { data: { error: 'custom_attributes.x is managed' } },
      })
    ).toBe('custom_attributes.x is managed');
    expect(
      serverErrorMessage({ response: { data: { message: 'Not allowed' } } })
    ).toBe('Not allowed');
  });

  it('falls back to the detail the contacts store keeps', () => {
    expect(serverErrorMessage({ contactErrorDetail: 'Detail' })).toBe('Detail');
  });

  it('reads the text an ExceptionWithMessage carries', () => {
    expect(serverErrorMessage(new ExceptionWithMessage('Refused'))).toBe(
      'Refused'
    );
  });

  it('is empty when there is nothing to show', () => {
    expect(serverErrorMessage(new Error('Network down'))).toBe('');
    expect(serverErrorMessage(undefined)).toBe('');
  });
});
