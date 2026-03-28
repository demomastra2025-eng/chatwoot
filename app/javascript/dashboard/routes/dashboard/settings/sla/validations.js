import { required, minLength } from '@vuelidate/validators';

export default {
  name: {
    required,
    minLength: minLength(2),
  },
};
