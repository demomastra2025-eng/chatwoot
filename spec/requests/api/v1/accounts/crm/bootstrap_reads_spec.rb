# frozen_string_literal: true

require 'rails_helper'

# The CRM list endpoints used to run the write-capable bootstrap (47-83 queries) on every GET. The first call
# provisions the defaults, later calls only read.
RSpec.describe 'CRM bootstrap on read endpoints', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/crm" }
  let(:write_statement) { /\A(INSERT|UPDATE|DELETE)\b/ }

  before { account.enable_features!('crm_deals', 'crm_tasks') }

  def read_queries(path)
    queries = sql_queries_during { get path, headers: headers, as: :json }
    expect(response).to have_http_status(:ok)
    queries
  end

  def forget_bootstrap_marker
    Redis::Alfred.delete(Crm::Bootstrap::AccountService.new(account: account).send(:bootstrapped_marker_key))
  end

  %w[pipelines task_types task_statuses task_outcomes deals].each do |endpoint|
    it "reads GET #{endpoint} without the bootstrap once the defaults were provisioned" do
      path = "#{base_path}/#{endpoint}"
      get path, headers: headers, as: :json # warm-up: provisions the defaults and fills the caches
      forget_bootstrap_marker

      with_bootstrap = read_queries(path)
      without_bootstrap = read_queries(path)

      expect(without_bootstrap.grep(write_statement)).to be_empty
      expect(without_bootstrap.size).to be < with_bootstrap.size
      expect(without_bootstrap.size).to be <= 20
    end
  end

  it 'creates the default pipeline, stages and task catalogs with the very first GET' do
    get "#{base_path}/pipelines", headers: headers, as: :json

    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('sales_pipeline')
    expect(account.crm_task_types.pluck(:code)).to include('task', 'call', 'meeting')
    expect(account.crm_task_statuses.pluck(:code)).to include('todo', 'done')
  end

  it 'does not run the bootstrap for another CRM read right after the first one' do
    get "#{base_path}/pipelines", headers: headers, as: :json
    performed = 0
    allow(Crm::Bootstrap::AccountService).to receive(:new).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap do |service|
        allow(service).to receive(:perform).and_wrap_original do |perform, *args|
          performed += 1
          perform.call(*args)
        end
      end
    end

    get "#{base_path}/task_types", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(performed).to eq(0)
  end

  it 'provisions the defaults again when the marker has expired' do
    get "#{base_path}/pipelines", headers: headers, as: :json
    account.crm_pipelines.destroy_all
    forget_bootstrap_marker

    get "#{base_path}/pipelines", headers: headers, as: :json

    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('sales_pipeline')
  end
end
