import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  records: [],
  dispatch: vi.fn(),
}));

vi.mock('../../../store', () => ({
  default: {
    state: { captainAssistants: { records: mocks.records } },
    dispatch: (...args) => mocks.dispatch(...args),
  },
}));

const { redirectHiddenAssistant } = await import('./assistantRouteGuard');

const toRoute = assistantId => ({
  params: { accountId: '1', assistantId },
});
const listRedirect = {
  name: 'captain_assistants_create_index',
  params: { accountId: '1' },
  replace: true,
};

describe('redirectHiddenAssistant', () => {
  beforeEach(() => {
    mocks.records.splice(0, mocks.records.length);
    mocks.dispatch.mockReset();
  });

  it('lets an AI agent from the loaded list through without a request', async () => {
    mocks.records.push({ id: 7, usage_mode: 'external_agent' });

    expect(await redirectHiddenAssistant(toRoute('7'))).toBe(true);
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });

  it('sends a loaded internal assistant to the list of agents', async () => {
    mocks.records.push({ id: 8, usage_mode: 'internal_assistant' });

    expect(await redirectHiddenAssistant(toRoute('8'))).toEqual(listRedirect);
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });

  it('looks up an assistant that is not loaded yet and lets an AI agent through', async () => {
    mocks.dispatch.mockResolvedValue({ id: 9, usage_mode: 'external_agent' });

    expect(await redirectHiddenAssistant(toRoute('9'))).toBe(true);
    expect(mocks.dispatch).toHaveBeenCalledWith('captainAssistants/show', 9);
  });

  it('sends an internal assistant opened by its direct link to the list of agents', async () => {
    mocks.dispatch.mockResolvedValue({
      id: 10,
      usage_mode: 'internal_assistant',
    });

    expect(await redirectHiddenAssistant(toRoute('10'))).toEqual(listRedirect);
  });

  it('keeps the navigation when the lookup fails', async () => {
    mocks.dispatch.mockRejectedValue(new Error('Not found'));

    expect(await redirectHiddenAssistant(toRoute('11'))).toBe(true);
  });

  it('ignores routes without an assistant id', async () => {
    expect(await redirectHiddenAssistant({ params: { accountId: '1' } })).toBe(
      true
    );
    expect(mocks.dispatch).not.toHaveBeenCalled();
  });
});
