require 'rails_helper'

RSpec.describe 'Raw form specialist schedule input', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, inherit_working_hours_from_account: false) }
  let(:valid_rule) { { weekday: '1', start_minute: '540', end_minute: '1020', active: 'off' } }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, account: account, resource: resource, weekday: 2)
    create(:scheduling_break_rule, account: account, resource: resource, weekday: 2)
  end

  def snapshot
    [resource.reload.attributes, resource.work_rules.order(:id).map(&:attributes), resource.break_rules.order(:id).map(&:attributes)]
  end

  def patch_form(rules_key, rules, standalone:)
    path = "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}"
    path = "#{path}/#{rules_key}" if standalone
    patch path, params: { 'name' => 'Updated specialist', rules_key => rules }, headers: headers
  end

  endpoints = { resource: false, standalone: true }
  malformed_cases = %i[null_only null_and_valid]
  %w[work_rules break_rules].each do |rules_key|
    endpoints.each do |endpoint, standalone|
      malformed_cases.each do |shape|
        it "rejects #{endpoint} #{rules_key} form #{shape} and preserves the entire saved state" do
          previous = snapshot
          rules = shape == :null_only ? [nil] : [nil, valid_rule]
          patch_form(rules_key, rules, standalone: standalone)

          expect(request.media_type).to eq('application/x-www-form-urlencoded')
          expect(Rack::Utils.parse_nested_query(request.raw_post).fetch(rules_key)).to include(nil)
          expect(response).to have_http_status(:unprocessable_content)
          expect(snapshot).to eq(previous)
        end
      end

      it "keeps valid #{endpoint} #{rules_key} forms compatible and preserves the other rule set" do
        other_key = rules_key == 'work_rules' ? :break_rules : :work_rules
        previous_other = resource.public_send(other_key).order(:id).map(&:attributes)
        patch_form(rules_key, [valid_rule], standalone: standalone)

        expect(response).to have_http_status(:ok)
        expect(resource.public_send(rules_key).reload.pluck(:weekday, :start_minute, :end_minute, :active)).to eq([[1, 540, 1020, false]])
        expect(resource.public_send(other_key).reload.order(:id).map(&:attributes)).to eq(previous_other)
      end
    end
  end

  it 'keeps both omitted sets when a form only updates the profile' do
    previous_work = resource.work_rules.order(:id).map(&:attributes)
    previous_breaks = resource.break_rules.order(:id).map(&:attributes)
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}", params: { name: 'Updated profile' }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(resource.reload.name).to eq('Updated profile')
    expect(resource.work_rules.order(:id).map(&:attributes)).to eq(previous_work)
    expect(resource.break_rules.order(:id).map(&:attributes)).to eq(previous_breaks)
  end
end
