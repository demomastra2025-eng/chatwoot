import { describe, expect, it } from 'vitest';

import {
  buildRequestTemplate,
  insertMissingRequestTemplateParams,
  insertRequestTemplateParam,
  requestTemplateUsesParam,
  templateBodyParams,
} from './requestTemplate';

const params = [
  {
    name: 'customer_name',
    type: 'string',
    source: 'context',
    request_location: 'template',
  },
  {
    name: 'metadata',
    type: 'object',
    source: 'agent',
    request_location: 'template',
  },
  {
    name: 'tenant_id',
    type: 'string',
    source: 'fixed',
    request_location: 'header',
  },
];

describe('custom tool request template helpers', () => {
  it('keeps only valid template parameters', () => {
    expect(
      templateBodyParams([
        ...params,
        { name: 'legacy_param' },
        { name: 'invalid-name', request_location: 'template' },
      ]).map(param => param.name)
    ).toEqual(['customer_name', 'metadata', 'legacy_param']);
  });

  it('ignores malformed legacy parameters without throwing', () => {
    expect(
      templateBodyParams([
        { type: 'string' },
        { name: 42, request_location: 'template' },
        { name: 'valid_name', request_location: 'template' },
      ])
    ).toEqual([{ name: 'valid_name', request_location: 'template' }]);
    expect(() => buildRequestTemplate([{ type: 'string' }])).not.toThrow();
    expect(insertRequestTemplateParam('{}', { name: 42 })).toEqual({
      template: '{}',
      inserted: false,
      reason: 'invalid_param',
    });
    expect(templateBodyParams({ name: 'not_an_array' })).toEqual([]);
    expect(templateBodyParams('not_an_array')).toEqual([]);
    expect(buildRequestTemplate({ name: 'not_an_array' })).toBe('');
  });

  it('builds a typed JSON template without duplicating header parameters', () => {
    expect(buildRequestTemplate(params)).toBe(`{
  "customer_name": {{ customer_name | json_value }},
  "metadata": {{ metadata | json_value }}
}`);
  });

  it('recognizes root and namespaced parameter references', () => {
    expect(
      requestTemplateUsesParam(
        '{"name": {{ params.customer_name | json_value }}}',
        'customer_name'
      )
    ).toBe(true);
    expect(
      requestTemplateUsesParam(
        '{"name":"{{ p.customer_name }}"}',
        'customer_name'
      )
    ).toBe(true);
    expect(
      requestTemplateUsesParam('{"name":"{{ contact.name }}"}', 'customer_name')
    ).toBe(false);
  });

  it('adds a missing field without overwriting a customized object', () => {
    const result = insertRequestTemplateParam(
      '{\n  "external_name": {{ customer_name | json_value }}\n}',
      params[1]
    );

    expect(result).toEqual({
      template: `{
  "external_name": {{ customer_name | json_value }},
  "metadata": {{ metadata | json_value }}
}`,
      inserted: true,
      reason: null,
    });
  });

  it('adds all missing fields and leaves used aliases untouched', () => {
    const result = insertMissingRequestTemplateParams(
      '{\n  "client": {{ customer_name | json_value }}\n}',
      params
    );

    expect(result.inserted).toBe(1);
    expect(result.template).toContain(
      '"client": {{ customer_name | json_value }}'
    );
    expect(result.template).toContain(
      '"metadata": {{ metadata | json_value }}'
    );
    expect(result.template).not.toContain('tenant_id');
  });

  it('does not modify a manually authored non-object template', () => {
    expect(
      insertMissingRequestTemplateParams('raw={{ customer_name }}', params)
    ).toEqual({
      template: 'raw={{ customer_name }}',
      inserted: 0,
      reason: 'invalid_object',
    });
  });
});
