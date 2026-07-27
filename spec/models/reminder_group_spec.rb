require 'rails_helper'

RSpec.describe ReminderGroup do
  it 'preserves an omitted step id on update' do
    group = create(:reminder_group)
    original_step_id = group.touches.first['step_id']

    group.update!(touches: [group.touches.first.except('step_id').merge('body' => 'Updated body')])

    expect(group.reload.touches.first['step_id']).to eq(original_step_id)
  end

  it 'rejects a step entity kind outside the plan scope' do
    group = build(
      :reminder_group,
      entity_kinds: ['appointment'],
      touches: [{ entity_kind: 'deal', body: 'Deal follow-up' }]
    )

    expect(group).not_to be_valid
    expect(group.errors[:touches]).to include('contains entity kinds outside plan scope: deal')
  end

  it 'keeps legacy steps without an explicit entity kind valid' do
    group = build(:reminder_group, entity_kinds: %w[appointment deal])

    expect(group).to be_valid
  end

  it 'rejects a plan entity kind without a matching or shared step' do
    group = build(
      :reminder_group,
      entity_kinds: %w[appointment deal],
      touches: [{ entity_kind: 'appointment', body: 'Appointment follow-up' }]
    )

    expect(group).not_to be_valid
    expect(group.errors[:touches]).to include('does not cover plan entity kinds: deal')
  end

  it 'allows a conversation-scoped post-delivery action in a mixed plan' do
    group = build(
      :reminder_group,
      entity_kinds: %w[conversation appointment],
      touches: [
        {
          entity_kind: 'conversation',
          body: 'Final conversation follow-up',
          post_delivery_action: 'resolve_conversation'
        },
        { entity_kind: 'appointment', body: 'Appointment follow-up' }
      ]
    )

    expect(group).to be_valid
  end

  it 'rejects a shared post-delivery action in a mixed plan' do
    group = build(
      :reminder_group,
      entity_kinds: %w[conversation appointment],
      touches: [
        {
          body: 'Shared follow-up',
          post_delivery_action: 'resolve_conversation'
        }
      ]
    )

    expect(group).not_to be_valid
    expect(group.errors[:touches]).to include('contains an unsupported post-delivery action')
  end
end
