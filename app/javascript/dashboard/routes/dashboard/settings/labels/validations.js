import { required, maxLength } from '@vuelidate/validators';

const hasControlCharacter = value =>
  Array.from(value).some(char => {
    const code = char.charCodeAt(0);
    return code < 32 || code === 127;
  });

export const validLabelCharacters = (str = '') => {
  const value = String(str || '');
  return !!value.trim() && !hasControlCharacter(value);
};

export const getLabelTitleErrorMessage = validation => {
  let errorMessage = '';
  if (!validation.title.$error) {
    errorMessage = '';
  } else if (!validation.title.required) {
    errorMessage = 'LABEL_MGMT.FORM.NAME.REQUIRED_ERROR';
  } else if (!validation.title.maxLength) {
    errorMessage = 'LABEL_MGMT.FORM.NAME.MAX_LENGTH_ERROR';
  } else if (!validation.title.validLabelCharacters) {
    errorMessage = 'LABEL_MGMT.FORM.NAME.VALID_ERROR';
  }
  return errorMessage;
};

export default {
  title: {
    required,
    maxLength: maxLength(120),
    validLabelCharacters,
  },
  description: {},
  color: {
    required,
  },
  showOnSidebar: {},
};
