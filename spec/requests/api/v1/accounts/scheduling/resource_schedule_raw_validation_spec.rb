require 'rails_helper'

RSpec.describe 'Raw specialist schedule input', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:resource) { create(:scheduling_resource, account: account, inherit_working_hours_from_account: false) }
  let(:valid_rule) { { weekday: 1, start_minute: 540, end_minute: 1020, active: true } }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, account: account, resource: resource, weekday: 2)
    create(:scheduling_break_rule, account: account, resource: resource, weekday: 2)
  end

  def patch_resource(payload)
    patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}", params: payload, headers: headers, as: :json
  end

  def snapshot
    [resource.reload.attributes, resource.work_rules.order(:id).map(&:attributes), resource.break_rules.order(:id).map(&:attributes)]
  end

  def expect_invalid_payload(rules_key, value)
    previous = snapshot
    patch_resource({ name: 'Must not persist' }.merge(rules_key => value))
    expect(response).to have_http_status(:unprocessable_content)
    expect(snapshot).to eq(previous)
  end

  invalid_attributes = {
    weekday_word: { weekday: 'monday' }, weekday_fraction: { weekday: 1.9 }, weekday_array: { weekday: [1] },
    start_word: { start_minute: 'bad' }, start_fraction: { start_minute: 540.5 }, start_object: { start_minute: { value: 540 } },
    end_fraction: { end_minute: 1020.5 }, end_array: { end_minute: [1020] },
    active_word: { active: 'bad' }, active_blank: { active: '' }, active_nil: { active: nil },
    active_fraction: { active: 0.5 }, active_array: { active: [false] }
  }
  invalid_shapes = { object: { weekday: 1, start_minute: 540, end_minute: 1020, active: true }, empty_object: {}, scalar: 'bad',
                     null: nil, null_item: [nil], scalar_item: ['bad'], array_item: [[]] }
  boolean_values = { true => true, false => false, 1 => true, 0 => false, '1' => true, '0' => false,
                     'true' => true, 'false' => false, 't' => true, 'f' => false, 'on' => true, 'off' => false,
                     'TRUE' => true, 'FALSE' => false }
  form_rule = { weekday: '1', start_minute: '540', end_minute: '1020', active: 'off' }

  %w[work_rules break_rules].each do |rules_key|
    invalid_attributes.each do |label, replacement|
      it "rejects #{rules_key} #{label} and rolls back profile and both sets" do
        expect_invalid_payload(rules_key, [valid_rule.merge(replacement)])
      end
    end

    invalid_shapes.each do |label, value|
      it "rejects #{rules_key} shape #{label} without treating it as omission or clear" do
        expect_invalid_payload(rules_key, value)
      end
    end

    it "normalizes exact integers and standard booleans in #{rules_key}" do
      boolean_values.each do |value, expected|
        patch_resource(rules_key => [{ weekday: '1.0', start_minute: '540.0', end_minute: 1020.0, active: value }])
        expect(response).to have_http_status(:ok)
        expect(resource.public_send(rules_key).reload.pluck(:weekday, :start_minute, :end_minute, :active))
          .to eq([[1, 540, 1020, expected]])
      end
    end

    it "preserves the model active default when omitted from #{rules_key}" do
      patch_resource(rules_key => [valid_rule.except(:active)])
      expect(response).to have_http_status(:ok)
      expect(resource.public_send(rules_key).reload.first.active).to be(true)
    end

    it "keeps form-encoded input compatible for the standalone #{rules_key} API" do
      patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/#{rules_key}",
            params: { rules_key => [form_rule] }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(resource.public_send(rules_key).reload.pluck(:weekday, :start_minute, :end_minute, :active)).to eq([[1, 540, 1020, false]])
    end

    it "clears only explicitly empty #{rules_key} and preserves the omitted set" do
      other_key = rules_key == 'work_rules' ? :break_rules : :work_rules
      preserved_ids = resource.public_send(other_key).pluck(:id)
      patch_resource(rules_key => [])

      expect(response).to have_http_status(:ok)
      expect(resource.public_send(rules_key).reload).to be_empty
      expect(resource.public_send(other_key).reload.pluck(:id)).to eq(preserved_ids)
    end

    it "whitelists #{rules_key} fields and ignores foreign nested ownership and IDs" do
      foreign_resource = create(:scheduling_resource)
      factory = rules_key == 'work_rules' ? :scheduling_work_rule : :scheduling_break_rule
      foreign_rule = create(factory, resource: foreign_resource, account: foreign_resource.account)
      previous_foreign = [foreign_resource.attributes, foreign_rule.attributes]
      raw_rule = valid_rule.merge(id: foreign_rule.id, account_id: foreign_resource.account_id, resource_id: foreign_resource.id)
      patch_resource(rules_key => [raw_rule])

      expect(response).to have_http_status(:ok)
      expect(resource.public_send(rules_key).reload.pluck(:resource_id, :account_id)).to eq([[resource.id, account.id]])
      expect([foreign_resource.reload.attributes, foreign_rule.reload.attributes]).to eq(previous_foreign)
    end

    it "rolls back everything with foreign nested #{rules_key} IDs and invalid raw values" do
      foreign_resource = create(:scheduling_resource)
      factory = rules_key == 'work_rules' ? :scheduling_work_rule : :scheduling_break_rule
      foreign_rule = create(factory, resource: foreign_resource, account: foreign_resource.account)
      previous_foreign = [foreign_resource.attributes, foreign_rule.attributes]
      raw_rule = valid_rule.merge(id: foreign_rule.id, account_id: foreign_resource.account_id, resource_id: foreign_resource.id, active: 'bad')
      expect_invalid_payload(rules_key, [raw_rule])
      expect([foreign_resource.reload.attributes, foreign_rule.reload.attributes]).to eq(previous_foreign)
    end

    it "uses the same raw validator in the standalone #{rules_key} API" do
      previous = snapshot
      patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/#{rules_key}",
            params: { rules_key => [valid_rule.merge(start_minute: 'bad')] }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(snapshot).to eq(previous)
    end

    it "rejects malformed shape in the standalone #{rules_key} API" do
      previous = snapshot
      invalid_shapes.values_at(:null, :null_item).each do |value|
        patch "/api/v1/accounts/#{account.id}/scheduling/resources/#{resource.id}/#{rules_key}",
              params: { rules_key => value }, headers: headers, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(snapshot).to eq(previous)
      end
    end
  end

  [{ value: 'Lunch' }, ['Lunch']].each do |value|
    it "rejects non-string break title #{value.class}" do
      expect_invalid_payload('break_rules', [valid_rule.merge(title: value)])
    end
  end
end
