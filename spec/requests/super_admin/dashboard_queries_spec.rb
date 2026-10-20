# frozen_string_literal: true

require 'rails_helper'

# «Сводка» runs the figures of the tiles, the checks of «Нужно проверить» and the table of the accounts when it is opened (and not
# again for a couple of minutes). However many accounts the platform has, that must be a handful of queries: one per kind of thing,
# never one per account.
RSpec.describe 'Super admin «Сводка»: queries', type: :request do
  let(:super_admin) { create(:super_admin) }
  # The most queries the page may run; it ran 0 below this number when it was measured, with room for a query of the layout
  let(:query_limit) { 150 }

  before do
    allow(Llm::OpenRouterKeyHealth).to receive(:metadata).and_return({ status: 'valid' })
    allow(SuperAdmin::QueueStats).to receive(:read)
      .and_return(SuperAdmin::QueueStats::Result.new(busy: 0, enqueued: 0, scheduled: 0, retries: 0, dead: 0, processed: 0, failed: 0, queues: []))
    sign_in(super_admin, scope: :super_admin)
  end

  after do
    Account.pluck(:id).each { |id| Redis::Alfred.delete("account:#{id}:storage_overview_v1") }
    Channel::TelegramPersonal.pluck(:id).each { |id| Redis::Alfred.delete(Reauthorizable.required_key(Channel::TelegramPersonal, id)) }
  end

  # An account with a problem of every kind the page looks for: a trial that ends soon, a disk that is nearly full, a channel that
  # needs a new login, a message that did not go out
  def add_accounts(count)
    Array.new(count) do |index|
      account = create(:account, name: "Аккаунт #{index}", custom_attributes: { 'plan_type' => 'trial', 'trial_expires_at' => (index + 1).hours.from_now.iso8601 })
      create(:channel_telegram_personal, account: account, connection_state: 'auth_required')
      create(:message, account: account, status: :failed)
      Redis::Alfred.set("account:#{account.id}:storage_overview_v1",
                        JSON.generate(limits: { total_count: 100, consumed: 97, unlimited: false, current_available: 3 }))
      account
    end
  end

  # The queries the page runs for one visit (the ones the database answers from its own cache and the plumbing of a transaction are not counted)
  def queries_for_a_visit
    queries = []
    counter = lambda do |*, payload|
      queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached] || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get '/super_admin' }
    expect(response).to have_http_status(:ok)
    queries
  end

  it 'runs the same number of queries for twelve accounts as for two' do
    add_accounts(2)
    few = queries_for_a_visit

    add_accounts(10)
    many = queries_for_a_visit

    expect(many.size).to eq(few.size), "two accounts: #{few.size} queries, twelve: #{many.size}\n#{(many - few).first(10).join("\n")}"
  end

  it 'shows the problems of all of them while it does so' do
    add_accounts(12)

    queries = queries_for_a_visit

    expect(queries.size).to be < query_limit
    page = Nokogiri::HTML(response.body)
    expect(page.at_css("[data-testid='dashboard-checklist-count']").text.squish.delete(' ').to_i).to be >= 36
  end

  it 'asks the database for the figures of the tiles once, and for the checks once, not once for each of them' do
    add_accounts(3)

    queries = queries_for_a_visit

    expect(queries.grep(/FROM "messages"/).size).to be <= 3
    expect(queries.grep(/FROM "conversations"/).size).to be <= 2
  end
end
