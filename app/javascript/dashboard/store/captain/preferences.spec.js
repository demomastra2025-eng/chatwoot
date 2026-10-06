import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createPinia, setActivePinia } from 'pinia';

const { getMock } = vi.hoisted(() => ({ getMock: vi.fn() }));

vi.mock('dashboard/api/captain/preferences', () => ({
  default: { get: getMock },
}));

const { useCaptainConfigStore } = await import('./preferences');

describe('Captain preferences store', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    getMock.mockReset();
  });

  it('shares an in-flight preferences request between profile forms', async () => {
    let resolveRequest;
    getMock.mockReturnValue(
      new Promise(resolve => {
        resolveRequest = resolve;
      })
    );
    const store = useCaptainConfigStore();

    const first = store.fetch();
    const second = store.fetch();

    expect(getMock).toHaveBeenCalledTimes(1);
    resolveRequest({ data: { features: { assistant: { models: [] } } } });
    await Promise.all([first, second]);
    expect(store.features.assistant.models).toEqual([]);
  });
});
