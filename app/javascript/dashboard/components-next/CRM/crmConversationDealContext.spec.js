import { describe, expect, it } from 'vitest';

import {
  buildCrmDealLookupParams,
  buildCrmDealSourceContext,
  mergeUniqueCrmDeals,
  selectBestCrmDealForContext,
  sortCrmDealsForContext,
} from './crmConversationDealContext';

describe('crmConversationDealContext', () => {
  it('builds a contact-first conversation source context', () => {
    const context = buildCrmDealSourceContext({
      id: 11963,
      display_id: 185,
      meta: { sender: { id: 77, name: 'Aruzhan' } },
    });

    expect(context).toMatchObject({
      contactId: 77,
      sourceType: 'conversation',
      originatingConversationDisplayId: '#185',
      originatingConversationId: 185,
      originatingCommunicationThreadId: '',
    });
    expect(buildCrmDealLookupParams(context)).toEqual({ contact_id: 77 });
  });

  it('builds a communication-thread source context without treating the thread id as a conversation id', () => {
    const context = buildCrmDealSourceContext({
      id: 41,
      is_communication_thread: true,
      communication_thread_id: 41,
      meta: { sender: { id: 77, name: 'Aruzhan' } },
    });

    expect(context).toMatchObject({
      contactId: 77,
      sourceType: 'communication_thread',
      originatingCommunicationThreadDisplayId: '#41',
      originatingCommunicationThreadId: 41,
      originatingConversationId: '',
    });
    expect(buildCrmDealLookupParams(context)).toEqual({ contact_id: 77 });
  });

  it('falls back to source lookup only when contact context is absent', () => {
    expect(
      buildCrmDealLookupParams(
        buildCrmDealSourceContext({ id: 41, is_communication_thread: true })
      )
    ).toEqual({ originating_communication_thread_id: 41 });

    expect(
      buildCrmDealLookupParams(buildCrmDealSourceContext({ id: 9 }))
    ).toEqual({ originating_conversation_id: 9 });
  });

  it('selects the best deal by contact while preferring the current source and open deals', () => {
    const context = buildCrmDealSourceContext({
      id: 41,
      is_communication_thread: true,
      meta: { sender: { id: 77 } },
    });
    const staleClosedDeal = {
      id: 1,
      primaryContactId: 77,
      closedAt: '2026-06-01T00:00:00Z',
      updatedAt: '2026-06-23T12:00:00Z',
    };
    const openContactDeal = {
      id: 2,
      dealContacts: [{ contactId: 77 }],
      updatedAt: '2026-06-22T12:00:00Z',
    };
    const exactThreadDeal = {
      id: 3,
      primaryContactId: 77,
      originatingCommunicationThreadDisplayId: 41,
      updatedAt: '2026-06-20T12:00:00Z',
    };

    expect(
      selectBestCrmDealForContext(
        [staleClosedDeal, openContactDeal, exactThreadDeal],
        context
      )
    ).toEqual(exactThreadDeal);
  });

  it('sorts all contact deals for the conversation sidebar accordion', () => {
    const context = buildCrmDealSourceContext({
      id: 41,
      is_communication_thread: true,
      meta: { sender: { id: 77 } },
    });
    const unrelatedDeal = { id: 9, primaryContactId: 88 };
    const staleClosedDeal = {
      id: 1,
      primaryContactId: 77,
      closedAt: '2026-06-01T00:00:00Z',
      updatedAt: '2026-06-23T12:00:00Z',
    };
    const openContactDeal = {
      id: 2,
      dealContacts: [{ contactId: 77 }],
      updatedAt: '2026-06-22T12:00:00Z',
    };
    const exactThreadDeal = {
      id: 3,
      primaryContactId: 77,
      originatingCommunicationThreadDisplayId: 41,
      updatedAt: '2026-06-20T12:00:00Z',
    };

    expect(
      sortCrmDealsForContext(
        [staleClosedDeal, unrelatedDeal, openContactDeal, exactThreadDeal],
        context
      ).map(deal => deal.id)
    ).toEqual([3, 2, 1]);
  });

  it('merges contact and source lookups without duplicating deals', () => {
    expect(
      mergeUniqueCrmDeals(
        [{ id: 1, title: 'Contact deal' }],
        [
          { id: 1, title: 'Same contact deal' },
          { id: 2, title: 'Legacy source-only deal' },
        ]
      )
    ).toEqual([
      { id: 1, title: 'Same contact deal' },
      { id: 2, title: 'Legacy source-only deal' },
    ]);
  });
});
