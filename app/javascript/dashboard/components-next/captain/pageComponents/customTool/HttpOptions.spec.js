import { shallowMount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import HttpOptions from './HttpOptions.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
}));

const buildOptions = overrides => ({
  timeout: { open_seconds: 10, read_seconds: 30 },
  retry: {
    enabled: false,
    max_attempts: 2,
    backoff_ms: 250,
    statuses: [502, 503, 504],
  },
  redirects: { enabled: false, max_redirects: 3 },
  idempotency: { enabled: false },
  pagination: {
    enabled: false,
    mode: 'page_parameter',
    parameter_name: 'page',
    start_page: 1,
    max_pages: 10,
    interval_ms: 0,
    items_path: null,
    next_url_path: null,
  },
  batching: {
    enabled: false,
    items_parameter: null,
    batch_size: 50,
    interval_ms: 0,
  },
  ...overrides,
});

const buildWrapper = props =>
  shallowMount(HttpOptions, {
    props: {
      modelValue: buildOptions(),
      httpMethod: 'GET',
      paramSchema: [],
      ...props,
    },
  });

describe('HttpOptions', () => {
  it('rejects unsafe cross-field combinations', () => {
    const wrapper = buildWrapper({
      httpMethod: 'POST',
      modelValue: buildOptions({
        retry: {
          enabled: true,
          max_attempts: 2,
          backoff_ms: 250,
          statuses: [503],
        },
        pagination: {
          enabled: true,
          mode: 'next_url',
          parameter_name: 'page',
          start_page: 1,
          max_pages: 26,
          interval_ms: 0,
          items_path: 'data',
          next_url_path: null,
        },
      }),
    });

    expect(wrapper.vm.validate()).toBe(false);
  });

  it('accepts retries without idempotency for read-only OPTIONS requests', () => {
    const wrapper = buildWrapper({
      httpMethod: 'OPTIONS',
      modelValue: buildOptions({
        retry: {
          enabled: true,
          max_attempts: 2,
          backoff_ms: 250,
          statuses: [503],
        },
      }),
    });

    expect(wrapper.vm.validate()).toBe(true);
  });

  it('accepts bounded batching for an agent array parameter', () => {
    const wrapper = buildWrapper({
      modelValue: buildOptions({
        batching: {
          enabled: true,
          items_parameter: 'items',
          batch_size: 25,
          interval_ms: 100,
        },
      }),
      paramSchema: [
        {
          name: 'items',
          type: 'array',
          source: 'agent',
          required: true,
        },
      ],
    });

    expect(wrapper.vm.validate()).toBe(true);
  });

  it.each([
    [
      'disabled retry attempts',
      {
        retry: {
          enabled: false,
          max_attempts: 0,
          backoff_ms: 250,
          statuses: [503],
        },
      },
    ],
    [
      'disabled retry statuses',
      {
        retry: {
          enabled: false,
          max_attempts: 2,
          backoff_ms: 250,
          statuses: [418],
        },
      },
    ],
    [
      'disabled redirect count',
      { redirects: { enabled: false, max_redirects: 0 } },
    ],
    [
      'pagination start page',
      {
        pagination: {
          enabled: true,
          mode: 'page_parameter',
          parameter_name: 'page',
          start_page: -1,
          max_pages: 10,
          interval_ms: 0,
          items_path: null,
          next_url_path: null,
        },
      },
    ],
    [
      'pagination query parameter',
      {
        pagination: {
          enabled: true,
          mode: 'page_parameter',
          parameter_name: '1invalid',
          start_page: 1,
          max_pages: 10,
          interval_ms: 0,
          items_path: null,
          next_url_path: null,
        },
      },
    ],
    [
      'pagination JSON path',
      {
        pagination: {
          enabled: true,
          mode: 'next_url',
          parameter_name: 'page',
          start_page: 1,
          max_pages: 10,
          interval_ms: 0,
          items_path: 'data[]',
          next_url_path: 'links..next',
        },
      },
    ],
  ])('rejects backend-incompatible %s', (_name, overrides) => {
    const wrapper = buildWrapper({ modelValue: buildOptions(overrides) });

    expect(wrapper.vm.validate()).toBe(false);
  });
});
