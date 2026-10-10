require 'rails_helper'

RSpec.describe Captain::DealContext do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:context) { described_class.new(account: account, conversation: conversation) }

  before { account.enable_features!('crm_deals') }

  def linked_deal(**attributes)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, **attributes)
    create(:crm_deal_contact, account: account, contact: contact, deal: deal)
    deal
  end

  it 'counts a 300-deal history in SQL and instantiates only the 9 displayed deal rows' do
    5.times { |index| linked_deal(title: "Active #{index}", updated_at: index.days.ago) }
    historical = linked_deal(closed_at: 2.days.ago)
    attributes = historical.attributes.except('id').merge('external_ref' => nil, 'idempotency_key' => nil)
    ids = Crm::Deal.insert_all!(294.times.map { |index| attributes.merge('title' => "History #{index}") }, returning: %w[id]).rows.flatten
    Crm::DealContact.insert_all!(ids.map do |id|
      { account_id: account.id, deal_id: id, contact_id: contact.id, primary: false, created_at: Time.current, updated_at: Time.current }
    end)
    instantiated = 0
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      instantiated += payload[:record_count] if payload[:class_name] == 'Crm::Deal'
    end
    summary = ActiveSupport::Notifications.subscribed(subscriber, 'instantiation.active_record') { context.summary }

    expect(summary).to include(total: 300, shown: 9, display: 'Показано 9 из 300')
    expect(summary[:groups].map { |group| [group[:shown], group[:total]] }).to eq([[5, 5], [4, 295]])
    expect(instantiated).to eq(9)
  end

  it 'excludes unrelated contact/thread deals, another account and contacts sharing a phone' do
    own = linked_deal
    other = create(:contact, account: account, phone_number: contact.phone_number)
    unrelated = create(:crm_deal, account: account, originating_conversation: conversation)
    create(:crm_deal_contact, account: account, contact: other, deal: unrelated)
    foreign = create(:crm_deal)

    expect(context.summary[:groups].flat_map { |group| group[:items].pluck(:id) }).to eq([own.id])
    expect(context.deals.pluck(:id)).not_to include(unrelated.id, foreign.id)
  end

  it 'uses actual archive/close dates and includes terminal stages with an explicitly labelled unknown event date' do
    older = linked_deal(closed_at: 10.days.ago, updated_at: Time.current)
    recent = linked_deal(archived_at: 1.day.ago, closed_at: 5.days.ago, updated_at: 20.days.ago)
    won = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won')
    unknown = linked_deal(stage: won, created_at: 2.days.ago, closed_at: nil)
    items = context.summary[:groups].last[:items]

    expect(items.pluck(:id)).to eq([recent.id, unknown.id, older.id])
    expect(items.second[:history_at_source]).to eq('created_at_fallback_event_time_unknown')
  end
end
