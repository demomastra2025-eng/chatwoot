FactoryBot.define do
  factory :crm_stage_field_requirement, class: 'Crm::StageFieldRequirement' do
    stage factory: :crm_stage
    account { stage.account }
    field_key { 'description' }
    required { true }
    validation { {} }
    role_exemptions { [] }
  end
end
