import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ref } from 'vue';
import { useCopilotReply } from '../useCopilotReply';
import TasksAPI from 'dashboard/api/captain/tasks';

const mockProcessEvent = vi.fn();
const mockFollowUp = vi.fn();
const mockConversationId = ref(42);
const mockCurrentChat = ref({ id: 42 });

vi.mock('dashboard/composables/useCaptain', () => ({
  useCaptain: () => ({
    processEvent: mockProcessEvent,
    followUp: mockFollowUp,
    currentChat: mockCurrentChat,
    conversationId: mockConversationId,
  }),
}));

vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(),
  useTrack: vi.fn(),
}));

vi.mock('dashboard/api/captain/tasks', () => ({
  default: {
    approveAction: vi.fn(),
    rejectAction: vi.fn(),
    feedback: vi.fn(() => Promise.resolve()),
  },
}));

describe('useCopilotReply', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockConversationId.value = 42;
    mockCurrentChat.value = { id: 42 };
  });

  it('populates pendingActions from reply_suggestion and handles approveAction and rejectAction', async () => {
    const sampleAction = {
      action_id: 'act-55',
      tool_name: 'create_appointment',
      status: 'pending',
      title: 'Записать на приём',
      digest: 'dig-55',
    };

    mockProcessEvent.mockResolvedValueOnce({
      message: 'Можем записать вас на 10:00.',
      followUpContext: { event_name: 'reply_suggestion' },
      pendingActions: [sampleAction],
      requestId: 'req-1',
    });

    const copilot = useCopilotReply();
    await copilot.execute('reply_suggestion');

    expect(copilot.generatedContent.value).toBe('Можем записать вас на 10:00.');
    expect(copilot.pendingActions.value).toEqual([sampleAction]);

    TasksAPI.approveAction.mockResolvedValueOnce({
      data: {
        ok: true,
        status: 'approved',
        action: { ...sampleAction, status: 'approved' },
      },
    });

    await copilot.approveAction(sampleAction);

    expect(TasksAPI.approveAction).toHaveBeenCalledWith({
      actionId: 'act-55',
      conversationId: 42,
      digest: 'dig-55',
    });
    expect(copilot.pendingActions.value[0].status).toBe('approved');
  });

  it('updates action status to rejected when rejectAction is called', async () => {
    const sampleAction = {
      action_id: 'act-56',
      tool_name: 'cancel_appointment',
      status: 'pending',
      title: 'Отменить запись на приём',
    };

    mockProcessEvent.mockResolvedValueOnce({
      message: 'Отменяем вашу запись?',
      pendingActions: [sampleAction],
      requestId: 'req-2',
    });

    const copilot = useCopilotReply();
    await copilot.execute('reply_suggestion');

    TasksAPI.rejectAction.mockResolvedValueOnce({
      data: {
        ok: true,
        status: 'rejected',
        action: { ...sampleAction, status: 'rejected' },
      },
    });

    await copilot.rejectAction(sampleAction);

    expect(TasksAPI.rejectAction).toHaveBeenCalledWith({
      actionId: 'act-56',
      conversationId: 42,
    });
    expect(copilot.pendingActions.value[0].status).toBe('rejected');
  });

  it('retains pendingActions after accept() and isolates them per conversation', async () => {
    const sampleAction = {
      action_id: 'act-90',
      tool_name: 'create_appointment',
      status: 'pending',
      title: 'Записать на приём',
      digest: 'dig-90',
    };

    mockProcessEvent.mockResolvedValueOnce({
      message: 'Запишем вас на завтра.',
      pendingActions: [sampleAction],
      requestId: 'req-90',
    });

    const copilot = useCopilotReply();
    await copilot.execute('reply_suggestion');
    const acceptedText = copilot.accept();

    expect(acceptedText).toBe('Запишем вас на завтра.');
    expect(copilot.showEditor.value).toBe(false);
    expect(copilot.pendingActions.value).toEqual([sampleAction]);

    // Switching to another conversation isolates pending actions
    mockConversationId.value = 99;
    mockCurrentChat.value = { id: 99 };
    copilot.reset();
    expect(copilot.pendingActions.value).toEqual([]);

    // Switching back to conversation 42 restores its unapproved action
    mockConversationId.value = 42;
    mockCurrentChat.value = { id: 42 };
    expect(copilot.pendingActions.value).toEqual([sampleAction]);
  });
});
