import { minValue, decimal } from '@vuelidate/validators';

export default {
  thresholdTime: {
    decimal,
    minValue: minValue(0.001),
  },
};
