import { describe, expect, it } from 'vitest';
import { shallowMount } from '@vue/test-utils';

import FileIcon from './FileIcon.vue';

const iconClass = type =>
  shallowMount(FileIcon, {
    props: { fileType: type },
    global: {
      stubs: {
        Icon: {
          props: ['icon'],
          template: '<i data-testid="icon" :class="icon" />',
        },
      },
    },
  })
    .find('[data-testid="icon"]')
    .attributes('class');

describe('FileIcon', () => {
  it('renders XML attachments with a document icon', () => {
    expect(iconClass('xml')).toContain('i-woot-file-txt');
  });

  it('renders PFX/P12 certificates with a certificate icon', () => {
    expect(iconClass('pfx')).toContain('i-lucide-shield-check');
    expect(iconClass('P12')).toContain('i-lucide-shield-check');
  });

  it('falls back to a generic document icon when extension is missing', () => {
    expect(iconClass('')).toContain('i-teenyicons-text-document-solid');
  });
});
