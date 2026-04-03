import {
  buildTemplateFieldReference,
  extractSingleTemplateFieldReference,
  renderTemplateFieldReferencePreview,
} from '../templateFieldReferences';
import { replaceTemplateVariables } from '../templateHelper';

describe('templateFieldReferences', () => {
  it('builds and extracts field references', () => {
    const reference = buildTemplateFieldReference({
      title: 'VIP Level',
      id: 'contact.custom_attributes.vip-level.v2',
    });

    expect(reference).toBe(
      '[VIP Level](field://contact.custom_attributes.vip-level.v2)'
    );
    expect(extractSingleTemplateFieldReference(reference)).toEqual({
      label: 'VIP Level',
      fieldId: 'contact.custom_attributes.vip-level.v2',
    });
  });

  it('renders labels in preview mode and preserves raw references for send mode', () => {
    const templateText = 'Hello {{name}}, your tier is {{tier}}';
    const processedParams = {
      body: {
        name: '[Contact Name](field://contact.name)',
        tier: '[VIP Level](field://contact.custom_attributes.vip-level.v2)',
      },
    };

    expect(
      replaceTemplateVariables(templateText, processedParams, {
        previewMode: true,
      })
    ).toBe('Hello Contact Name, your tier is VIP Level');

    expect(
      replaceTemplateVariables(templateText, processedParams, {
        previewMode: false,
      })
    ).toBe(
      'Hello [Contact Name](field://contact.name), your tier is [VIP Level](field://contact.custom_attributes.vip-level.v2)'
    );
  });

  it('renders reference labels in arbitrary text previews', () => {
    expect(
      renderTemplateFieldReferencePreview(
        'Track [Order ID](field://conversation.custom_attributes.order-id.v2)'
      )
    ).toBe('Track Order ID');
  });
});
