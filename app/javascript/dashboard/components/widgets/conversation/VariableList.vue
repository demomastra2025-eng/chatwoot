<script>
import { mapGetters } from 'vuex';
import { MESSAGE_VARIABLES } from 'shared/constants/messages';
import { sanitizeVariableSearchKey } from 'dashboard/helper/commons';
import MentionBox from '../mentions/MentionBox.vue';

export default {
  components: { MentionBox },
  props: {
    searchKey: {
      type: String,
      default: '',
    },
    allowedPrefixes: {
      type: Array,
      default: () => [],
    },
  },
  emits: ['selectVariable'],
  computed: {
    ...mapGetters({
      customAttributes: 'attributes/getAttributes',
    }),
    sanitizedSearchKey() {
      return sanitizeVariableSearchKey(this.searchKey);
    },
    allowedPrefixSet() {
      return new Set((this.allowedPrefixes || []).filter(Boolean));
    },
    items() {
      return [
        ...this.standardAttributeVariables,
        ...this.customAttributeVariables,
      ];
    },
    standardAttributeVariables() {
      return MESSAGE_VARIABLES.filter(variable => {
        return (
          this.isVariableAllowed(variable.key) &&
          (variable.label.includes(this.sanitizedSearchKey) ||
            variable.key.includes(this.sanitizedSearchKey))
        );
      }).map(variable => ({
        label: variable.key,
        key: variable.key,
        description: variable.label,
      }));
    },
    customAttributeVariables() {
      return this.customAttributes
        .filter(attribute => {
          const attributePrefix =
            attribute.attribute_model === 'conversation_attribute'
              ? 'conversation'
              : 'contact';

          return this.isVariableAllowed(attributePrefix);
        })
        .map(attribute => {
          const attributePrefix =
            attribute.attribute_model === 'conversation_attribute'
              ? 'conversation'
              : 'contact';

          return {
            label: `${attributePrefix}.custom_attribute.${attribute.attribute_key}`,
            key: `${attributePrefix}.custom_attribute.${attribute.attribute_key}`,
            description: attribute.attribute_description,
          };
        });
    },
  },
  methods: {
    isVariableAllowed(variableKey) {
      if (this.allowedPrefixSet.size === 0) return true;

      const prefix = String(variableKey || '').split('.')[0];
      return this.allowedPrefixSet.has(prefix);
    },
    handleVariableClick(item = {}) {
      this.$emit('selectVariable', item.key);
    },
  },
};
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <MentionBox
    v-if="items.length"
    type="variable"
    :items="items"
    @mention-select="handleVariableClick"
  />
</template>

<style scoped>
.variable--list-label {
  font-weight: 600;
}
</style>
