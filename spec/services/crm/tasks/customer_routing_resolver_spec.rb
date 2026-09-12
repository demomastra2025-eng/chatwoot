require 'rails_helper'

RSpec.describe Crm::Tasks::CustomerRoutingResolver do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:task_type) { create(:crm_task_type, account: account) }

  it 'prefers the deal linked to the current conversation over a newer fallback deal' do
    linked_owner = create(:user, account: account)
    fallback_owner = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: linked_owner)
    linked_deal = create(
      :crm_deal,
      account: account,
      owner: linked_owner,
      team: team,
      originating_conversation: conversation,
      updated_at: 2.days.ago
    )
    fallback_deal = create(:crm_deal, account: account, owner: fallback_owner, updated_at: 1.day.ago)
    create(:crm_deal_contact, account: account, contact: contact, deal: linked_deal)
    create(:crm_deal_contact, account: account, contact: contact, deal: fallback_deal)

    result = described_class.call(
      account: account,
      contact: contact,
      conversation: conversation,
      task_type: task_type
    )

    expect(result.deal).to eq(linked_deal)
    expect(result.assignee).to eq(linked_owner)
    expect(result.team).to eq(team)
  end

  it 'does not attach a linked deal whose inherited team conflicts with the priority route' do
    contact_owner = create(:user, account: account)
    route_team = create(:team, account: account)
    deal_team = create(:team, account: account)
    create(:team_member, team: route_team, user: contact_owner)
    contact.update!(owner: contact_owner)
    linked_deal = create(
      :crm_deal,
      account: account,
      team: deal_team,
      originating_conversation: conversation
    )
    create(:crm_deal_contact, account: account, contact: contact, deal: linked_deal)

    result = described_class.call(
      account: account,
      contact: contact,
      conversation: conversation,
      task_type: task_type
    )

    expect(result).to have_attributes(assignee: contact_owner, team: route_team, deal: nil)
  end

  it 'ignores an unrelated contact deal and falls back to the conversation assignee' do
    unrelated_owner = create(:user, account: account)
    conversation_owner = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: conversation_owner)
    unrelated_deal = create(:crm_deal, account: account, owner: unrelated_owner)
    create(:crm_deal_contact, account: account, contact: contact, deal: unrelated_deal)
    conversation.update!(assignee: conversation_owner)

    result = described_class.call(
      account: account,
      contact: contact,
      conversation: conversation,
      task_type: task_type
    )

    expect(result.deal).to be_nil
    expect(result.assignee).to eq(conversation_owner)
    expect(result.team).to eq(team)
  end

  it 'rejects a route whose assignee does not belong to the configured team' do
    contact_owner = create(:user, account: account)
    configured_team = create(:team, account: account)
    contact.update!(owner: contact_owner)
    task_type.update!(customer_task_team: configured_team)

    expect do
      described_class.call(
        account: account,
        contact: contact,
        conversation: conversation,
        task_type: task_type
      )
    end.to raise_error(Crm::Error, 'No eligible employee is available for this customer task type')
  end
end
