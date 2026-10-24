import { mount } from '@vue/test-utils';
import CustomAttribute from './CustomAttribute.vue';

const HINT = 'Filled in automatically from MedElement.';

const mountAttribute = (props = {}) =>
  mount(CustomAttribute, {
    props: {
      label: 'Address',
      attributeKey: 'address',
      value: 'Almaty',
      showActions: true,
      ...props,
    },
    global: {
      directives: { 'on-clickaway': {} },
      stubs: {
        HelperTextPopup: true,
        MultiselectDropdown: true,
        NextButton: {
          props: ['icon'],
          template: '<button type="button" :data-icon="icon" />',
        },
      },
    },
  });

const hasButton = (wrapper, icon) =>
  wrapper.find(`[data-icon="${icon}"]`).exists();

describe('CustomAttribute', () => {
  it('offers edit, copy and delete for an ordinary value', () => {
    const wrapper = mountAttribute();

    expect(hasButton(wrapper, 'i-lucide-pen')).toBe(true);
    expect(hasButton(wrapper, 'i-lucide-trash-2')).toBe(true);
    expect(hasButton(wrapper, 'i-lucide-clipboard')).toBe(true);
    expect(
      wrapper.find('[data-testid="custom-attribute-read-only-hint"]').exists()
    ).toBe(false);
  });

  describe('when another system owns the value', () => {
    it('shows the value and the reason, keeps copy, drops edit and delete', () => {
      const wrapper = mountAttribute({ readOnly: true, readOnlyHint: HINT });

      expect(wrapper.text()).toContain('Almaty');
      expect(
        wrapper.get('[data-testid="custom-attribute-read-only-hint"]').text()
      ).toBe(HINT);
      expect(hasButton(wrapper, 'i-lucide-clipboard')).toBe(true);
      expect(hasButton(wrapper, 'i-lucide-pen')).toBe(false);
      expect(hasButton(wrapper, 'i-lucide-trash-2')).toBe(false);
    });

    it('shows an empty value as a dash, still read-only', () => {
      const wrapper = mountAttribute({
        value: '',
        readOnly: true,
        readOnlyHint: HINT,
      });

      expect(wrapper.text()).toContain('---');
      expect(hasButton(wrapper, 'i-lucide-pen')).toBe(false);
    });

    it('does not start editing, update or delete', async () => {
      const wrapper = mountAttribute({ readOnly: true, readOnlyHint: HINT });

      wrapper.vm.onEdit();
      await wrapper.vm.$nextTick();
      wrapper.vm.onUpdate();
      wrapper.vm.onDelete();

      expect(wrapper.vm.isEditing).toBe(false);
      expect(wrapper.emitted('update')).toBeUndefined();
      expect(wrapper.emitted('delete')).toBeUndefined();
    });

    it('still lets the value be copied', async () => {
      const wrapper = mountAttribute({ readOnly: true, readOnlyHint: HINT });

      await wrapper.get('[data-icon="i-lucide-clipboard"]').trigger('click');

      expect(wrapper.emitted('copy')).toEqual([['Almaty']]);
    });
  });
});
