import {
  validLabelCharacters,
  getLabelTitleErrorMessage,
} from '../validations';

describe('#validLabelCharacters', () => {
  it('validates visible label text', () => {
    expect(validLabelCharacters('')).toEqual(false);
    expect(validLabelCharacters('str str')).toEqual(true);
    expect(validLabelCharacters('VIP клиент 💎')).toEqual(true);
    expect(validLabelCharacters('str_str')).toEqual(true);
    expect(validLabelCharacters('bad\nlabel')).toEqual(false);
  });
});

describe('#getLabelTitleErrorMessage', () => {
  const createValidation = titleValidation => ({
    title: {
      $error: titleValidation.$error,
      required: titleValidation.required,
      maxLength: titleValidation.maxLength,
      validLabelCharacters: titleValidation.validLabelCharacters,
    },
  });

  it('returns an empty string when there are no validation errors', () => {
    const validation = createValidation({
      $error: false,
      required: true,
      maxLength: true,
      validLabelCharacters: true,
    });

    expect(getLabelTitleErrorMessage(validation)).toEqual('');
  });

  it('returns a required error message when the title is required but not provided', () => {
    const validation = createValidation({
      $error: true,
      required: false,
      maxLength: true,
      validLabelCharacters: true,
    });

    expect(getLabelTitleErrorMessage(validation)).toEqual(
      'LABEL_MGMT.FORM.NAME.REQUIRED_ERROR'
    );
  });

  it('returns a maximum length error message when the title is too long', () => {
    const validation = createValidation({
      $error: true,
      required: true,
      maxLength: false,
      validLabelCharacters: true,
    });

    expect(getLabelTitleErrorMessage(validation)).toEqual(
      'LABEL_MGMT.FORM.NAME.MAX_LENGTH_ERROR'
    );
  });

  it('returns a valid label characters error message when the title has control characters', () => {
    const validation = createValidation({
      $error: true,
      required: true,
      maxLength: true,
      validLabelCharacters: false,
    });

    expect(getLabelTitleErrorMessage(validation)).toEqual(
      'LABEL_MGMT.FORM.NAME.VALID_ERROR'
    );
  });
});
