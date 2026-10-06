require 'rails_helper'

# The next_offset the search tool offers must be reachable within the per-run call budget of the loop guard; otherwise the
# tool says that further pages are not reachable. All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchSchedulingServicesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant, user: user) }

  before { account.enable_features!('scheduling') }

  def create_service(name, **attributes)
    create(:scheduling_service, account: account, name: name, **attributes)
  end

  def search(**arguments)
    JSON.parse(tool.execute(**arguments))
  end

  describe 'paging against the per-run call budget' do
    let(:budget) { Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_BY_TOOL.fetch('search_scheduling_services') }

    def seed(count)
      now = Time.current
      rows = Array.new(count) do |index|
        { account_id: account.id, name: format('УЗИ вариант %<number>04d', number: index), duration_min: 30, base_price: 0, active: true,
          custom_attributes: {}, created_at: now, updated_at: now }
      end
      Scheduling::Service.insert_all(rows) # rubocop:disable Rails/SkipsModelValidations
    end

    def walk(**arguments)
      pages = [search(**arguments)]
      pages << search(**arguments, offset: pages.last['next_offset']) while pages.last['next_offset']
      pages
    end

    it 'reaches all 200 services of a catalogue within four calls of one run' do
      expect(budget).to eq(4)
      seed(200)

      pages = walk(query: 'УЗИ')

      expect(pages.size).to be <= budget
      expect(pages.sum { |page| page['returned_count'] }).to eq(200)
      expect(pages.last).to include('has_more' => false, 'next_offset' => nil)
    end

    it 'says that further pages are not reachable in this run instead of offering an offset the guard would refuse' do
      seed((budget * 50) + 20)

      pages = walk(query: 'УЗИ')

      expect(pages.size).to eq(budget)
      expect(pages.last).to include('has_more' => true, 'next_offset' => nil)
      expect(pages.last['paging_instruction']).to include('not reachable in this run').and include('Refine the query')
      expect(pages.first).not_to have_key('paging_instruction')
    end

    it 'counts the budget in pages of the requested size, not in pages of 50' do
      seed(40)

      pages = walk(query: 'УЗИ', limit: 5)

      expect(pages.size).to eq(budget)
      expect(pages.last).to include('has_more' => true, 'next_offset' => nil)
      expect(pages.last['paging_instruction']).to be_present
    end
  end
end
